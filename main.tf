terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
}

# ===========================================================================
# Selector comun
# ===========================================================================
# Todas las politicas comparten el mismo alcance. Si cambia el filtro, cambia
# en un solo lugar y las 4 alertas quedan consistentes entre si.

locals {
  sub_matcher = join(", ", [
    "monitored_resource=\"pubsub_subscription\"",
    "subscription_id=~\"${var.subscription_include_regex}\"",
    "subscription_id!~\"${var.subscription_exclude_regex}\"",
  ])

  notification_channels = var.enable_notifications && var.teams_webhook_url != "" ? [google_monitoring_notification_channel.teams[0].id] : []

  # Interruptor propio para cero-ingreso: son ~236 politicas de una vez (todo
  # topic de prod del proyecto, alcance confirmado con el stakeholder), muy por
  # encima de las 1-a-la-vez de las otras 3 alertas. Arranca en modo silencioso
  # independiente de enable_notifications para poder observar un par de dias de
  # comportamiento real antes de conectar 236 fuentes nuevas a Teams de una vez.
  zero_ingress_notification_channels = var.enable_zero_ingress_notifications && var.teams_webhook_url != "" ? [google_monitoring_notification_channel.teams[0].id] : []

  all_topic_names = compact(split(",", data.external.pubsub_topics.result.names))

  zero_ingress_topics = [
    for t in local.all_topic_names : t
    if length(regexall(var.topic_include_regex, t)) > 0
    && length(regexall(var.topic_exclude_regex, t)) == 0
  ]
}

# El provider de Google no trae un data source nativo para listar topics de
# Pub/Sub por patron, asi que se descubren via `gcloud` en tiempo de plan/apply.
# Esto es lo que reemplaza a la lista manual de topics: en vez de mantener a
# mano cuales topics son "de prod", se detectan solos en cada plan/apply.
data "external" "pubsub_topics" {
  program = ["bash", "${path.module}/scripts/list_topics.sh"]
  query = {
    project_id = var.project_id
  }
}

# ===========================================================================
# Canal de notificacion: Power Automate -> Teams
# ===========================================================================
# La URL de Power Automate ya trae su propia firma SAS en el query string,
# por eso el auth_token va vacio: la autenticacion viene en la propia URL.

resource "google_monitoring_notification_channel" "teams" {
  count = var.teams_webhook_url != "" ? 1 : 0

  display_name = "Microsoft Teams - Pub/Sub Queue Alerts"
  type         = "webhook_tokenauth"

  labels = {
    url = var.teams_webhook_url
  }
}

# ===========================================================================
# ALERTA 1 - Mensaje sin consumir por mas de 15 minutos
# ===========================================================================
# Significa: el consumer esta caido o atascado.
#
# duration = "0s" a proposito. La metrica YA es una edad acumulada; agregar
# duracion la sumaria al SLA real (15 min de umbral + 5 de duracion = 20 min
# reales antes de enterarte).
#
# auto_close: cuando la cola se vacia, GCP deja de escribir esta metrica en
# lugar de reportar 0. Sin auto_close el incidente queda abierto para siempre.

resource "google_monitoring_alert_policy" "oldest_unacked_message_age" {
  display_name = "Pub/Sub | Unconsumed message > ${var.max_message_age_seconds / 60} min"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "Oldest message age exceeds SLA"

    condition_prometheus_query_language {
      query = "max by (subscription_id) (pubsub_googleapis_com:subscription_oldest_unacked_message_age{${local.sub_matcher}}) > ${var.max_message_age_seconds}"

      duration            = "0s"
      evaluation_interval = "60s"
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Pub/Sub: unconsumed message exceeds SLA"
    content   = <<-EOT
      A subscription has a message waiting more than ${var.max_message_age_seconds / 60} minutes without being consumed.

      **Subscription:** $${resource.label.subscription_id}
      **Project:** $${resource.label.project_id}

      **What to check:**
      1. Consumer status (is it running? is it acking?)
      2. Consumer application logs for repeated errors
      3. If the message is a poison pill, check the DLQ configuration
    EOT
  }

  notification_channels = local.notification_channels
}

# ===========================================================================
# ALERTA 2 - Backlog acumulado sostenido
# ===========================================================================
# Significa: el consumer no da abasto con el volumen entrante.
#
# El trabajo de "sostenido" lo hace `duration`, no la consulta: GCP exige que
# la condicion sea cierta de forma continua durante toda la ventana. Un pico
# que sube y baja en dos minutos no dispara nada.

resource "google_monitoring_alert_policy" "backlog_depth" {
  display_name = "Pub/Sub | Backlog >= ${var.backlog_threshold} messages sustained"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Undelivered messages above threshold"

    condition_prometheus_query_language {
      query = "sum by (subscription_id) (pubsub_googleapis_com:subscription_num_undelivered_messages{${local.sub_matcher}}) >= ${var.backlog_threshold}"

      duration            = var.backlog_duration
      evaluation_interval = "60s"
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Pub/Sub: accumulated backlog"
    content   = <<-EOT
      A subscription has accumulated ${var.backlog_threshold} or more undelivered messages, sustained.

      **Subscription:** $${resource.label.subscription_id}
      **Project:** $${resource.label.project_id}

      **What to check:**
      1. Consumer capacity: are there enough instances?
      2. Per-message processing latency
      3. Whether the ack deadline is enough for the real processing time
    EOT
  }

  notification_channels = local.notification_channels
}

# ===========================================================================
# ALERTA 3 - Cero ingreso (fallo upstream del Scheduler)
# ===========================================================================
# Significa: el Scheduler dejo de publicar. Es la unica senal para este fallo,
# porque los workers se ven perfectamente sanos: no tienen nada que hacer.
#
# Alcance real (confirmado en llamada con el stakeholder, no era un topic
# puntual del Scheduler): "todos los topics de prod", no una lista curada a
# mano. Por eso el alcance sale de local.zero_ingress_topics (descubierto via
# gcloud + filtrado por topic_include_regex/exclude_regex), no de una lista
# fija.
#
# Simplificacion consciente: el pedido original era comparar cada topic contra
# su propio promedio historico (ej. "normalmente publica 100/dia, avisa si un
# dia no publica nada"). Eso es deteccion de anomalia por topic y no es lo que
# esto hace - esto es una ventana de silencio fija (zero_ingress_window) igual
# para todos los topics. Cubre la mayor parte del valor pedido con una fraccion
# del esfuerzo; la version con baseline por topic queda pendiente si hace falta.
#
# Una politica por topic. absent_over_time solo devuelve algo si NINGUNA serie
# que coincida con el selector tiene datos; con un regex de varios topics, uno
# silencioso quedaria tapado por los demas.
#
# Requisito: la serie debe haber tenido datos en las ultimas ~24h. En un topic
# recien creado esta condicion no dispara.

resource "google_monitoring_alert_policy" "zero_ingress" {
  for_each = toset(local.zero_ingress_topics)

  display_name = "Pub/Sub | Zero messages published in ${var.zero_ingress_window} - ${each.value}"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "No publications on the topic"

    condition_prometheus_query_language {
      query = "absent_over_time(pubsub_googleapis_com:topic_send_request_count{monitored_resource=\"pubsub_topic\", topic_id=\"${each.value}\"}[${var.zero_ingress_window}])"

      duration            = "0s"
      evaluation_interval = "60s"
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Pub/Sub: upstream silence"
    content   = <<-EOT
      Topic `${each.value}` has not received any publication in ${var.zero_ingress_window}.

      Consumers may look healthy: they are idle because there is no work,
      not because they are functioning well.

      **What to check:**
      1. Cloud Scheduler job status
      2. Publisher credentials or permissions (expired?)
      3. Network connectivity to Pub/Sub from the source
    EOT
  }

  notification_channels = local.zero_ingress_notification_channels
}

# ===========================================================================
# ALERTA 4 - Tasa de crecimiento (degradacion parcial)
# ===========================================================================
# Significa: la cola crece mas rapido de lo que drena. Aviso temprano.
#
# No hace falta comparar ingress contra drain con dos metricas: por definicion
# d(backlog)/dt = ingress - drain. La derivada del backlog YA es esa diferencia,
# y evita un join entre labels de topic y de subscription que no se unen limpio.
#
# El segundo bloque es un guard: sin el, ir de 1 a 2 mensajes cuenta como
# crecimiento sostenido y llena Teams de falsos positivos.

resource "google_monitoring_alert_policy" "queue_growth_rate" {
  display_name = "Pub/Sub | Queue growing (ingress > drain) sustained"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Backlog with sustained positive slope"

    condition_prometheus_query_language {
      query = trimspace(<<-EOT
        (
          sum by (subscription_id) (
            deriv(pubsub_googleapis_com:subscription_num_undelivered_messages{${local.sub_matcher}}[10m])
          ) > 0
        )
        and
        (
          sum by (subscription_id) (
            pubsub_googleapis_com:subscription_num_undelivered_messages{${local.sub_matcher}}
          ) > ${var.growth_min_backlog}
        )
      EOT
      )

      duration            = var.growth_duration
      evaluation_interval = "60s"
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Pub/Sub: queue growing faster than it drains"
    content   = <<-EOT
      A subscription's backlog has been growing steadily: more messages are
      coming in than are being processed.

      **Subscription:** $${resource.label.subscription_id}

      This is an early warning. The total backlog may still look manageable,
      but the trend indicates insufficient capacity or partial consumer
      degradation.

      **What to check:**
      1. Recent change in published volume
      2. Partial consumer health: are some instances failing?
      3. Downstream dependency latency (database, external APIs)
    EOT
  }

  notification_channels = local.notification_channels
}
