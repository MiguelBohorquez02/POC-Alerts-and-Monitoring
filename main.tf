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
  display_name = "Pub/Sub | Mensaje sin consumir > ${var.max_message_age_seconds / 60} min"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "Edad del mensaje mas viejo supera el SLA"

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
    subject   = "Pub/Sub: mensaje sin consumir supera el SLA"
    content   = <<-EOT
      Una subscription tiene un mensaje esperando mas de ${var.max_message_age_seconds / 60} minutos sin ser consumido.

      **Subscription:** $${resource.label.subscription_id}
      **Proyecto:** $${resource.label.project_id}

      **Que revisar:**
      1. Estado del consumer (esta corriendo? esta acking?)
      2. Logs de la aplicacion consumidora en busca de errores repetidos
      3. Si el mensaje es un poison pill, verificar la configuracion de DLQ
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
  display_name = "Pub/Sub | Backlog >= ${var.backlog_threshold} mensajes sostenido"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Mensajes sin entregar por encima del umbral"

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
    subject   = "Pub/Sub: backlog acumulado"
    content   = <<-EOT
      Una subscription acumula ${var.backlog_threshold} o mas mensajes sin entregar de forma sostenida.

      **Subscription:** $${resource.label.subscription_id}
      **Proyecto:** $${resource.label.project_id}

      **Que revisar:**
      1. Capacidad del consumer: hay suficientes instancias?
      2. Latencia de procesamiento por mensaje
      3. Si el ack deadline es suficiente para el tiempo real de proceso
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
# Una politica por topic. absent_over_time solo devuelve algo si NINGUNA serie
# que coincida con el selector tiene datos; con un regex de varios topics, uno
# silencioso quedaria tapado por los demas.
#
# Requisito: la serie debe haber tenido datos en las ultimas ~24h. En un topic
# recien creado esta condicion no dispara.

resource "google_monitoring_alert_policy" "zero_ingress" {
  for_each = toset(var.monitored_topics)

  display_name = "Pub/Sub | Cero mensajes publicados en ${var.zero_ingress_window} - ${each.value}"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Sin publicaciones en el topic"

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
    subject   = "Pub/Sub: silencio upstream"
    content   = <<-EOT
      El topic `${each.value}` no ha recibido ninguna publicacion en ${var.zero_ingress_window}.

      Los consumers pueden verse sanos: estan inactivos porque no hay trabajo,
      no porque esten funcionando bien.

      **Que revisar:**
      1. Estado del job de Cloud Scheduler
      2. Credenciales o permisos del publisher (expiraron?)
      3. Conectividad de red hacia Pub/Sub desde el origen
    EOT
  }

  notification_channels = local.notification_channels
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
  display_name = "Pub/Sub | Cola creciendo (ingress > drain) sostenido"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Backlog con pendiente positiva sostenida"

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
    subject   = "Pub/Sub: la cola crece mas rapido de lo que drena"
    content   = <<-EOT
      El backlog de una subscription lleva creciendo de forma sostenida: entran
      mas mensajes de los que se procesan.

      **Subscription:** $${resource.label.subscription_id}

      Esto es un aviso temprano. El backlog total todavia puede parecer
      manejable, pero la tendencia indica capacidad insuficiente o degradacion
      parcial del consumer.

      **Que revisar:**
      1. Cambio reciente en el volumen publicado
      2. Salud parcial del consumer: algunas instancias fallando?
      3. Latencia de dependencias downstream (base de datos, APIs externas)
    EOT
  }

  notification_channels = local.notification_channels
}
