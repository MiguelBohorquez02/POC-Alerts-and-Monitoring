variable "project_id" {
  description = "Proyecto de GCP donde viven las subscriptions y las alert policies."
  type        = string
  default     = "gcp-gah-uks-pdn-aah-01"
}

# ---------------------------------------------------------------------------
# Alcance: qué subscriptions se monitorean
# ---------------------------------------------------------------------------

variable "subscription_include_regex" {
  description = <<-EOT
    Regex (RE2, anclado) de las subscriptions a monitorear.
    Por defecto: todas las productivas del servicio account-customer-v1.
    Ajustar aqui cuando se confirme el alcance real del proyecto.

    "(.*-)?prod(-.*)?" en vez de ".*-prod-.*": la variante corta
    "...subscriber-prod-<n>-sub-<n>" (sin un segmento descriptivo entre
    "subscriber" y "prod") no trae el guion extra que ".*-prod-.*" exige,
    asi que con el regex viejo esa subscription real de prod quedaba fuera
    del monitoreo sin ningun aviso.
  EOT
  type        = string
  default     = "eventarc-europe-west2-account-customer-v1-subscriber-(.*-)?prod(-.*)?"
}

variable "subscription_exclude_regex" {
  description = <<-EOT
    Regex de subscriptions a excluir. Por defecto se excluyen las colas de error:
    en una DLQ cualquier mensaje ya es una anomalia y que quede sin consumir puede
    ser el comportamiento esperado, asi que la logica de estas 4 alertas no aplica.
  EOT
  type        = string
  default     = ".*error.*"
}

variable "monitored_topics" {
  description = <<-EOT
    Lista de topic_id para la alerta de cero-ingreso. Se crea UNA politica por topic.
    No se puede usar un regex: absent_over_time solo dispara si NINGUNA serie tiene
    datos, asi que un topic silencioso quedaria tapado por los demas.

    Dejar vacio para no crear ninguna politica de cero-ingreso.
  EOT
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Umbrales (calibrar con datos reales antes de fijar)
# ---------------------------------------------------------------------------

variable "max_message_age_seconds" {
  description = "Alerta 1: edad maxima del mensaje mas viejo sin consumir. 900 = 15 min."
  type        = number
  default     = 900
}

variable "backlog_threshold" {
  description = "Alerta 2: cantidad de mensajes sin entregar que dispara la alerta."
  type        = number
  default     = 10
}

variable "backlog_duration" {
  description = "Alerta 2: cuanto debe sostenerse el backlog. La condicion debe ser cierta de forma continua."
  type        = string
  default     = "600s"
}

variable "zero_ingress_window" {
  description = "Alerta 3: ventana de silencio que dispara la alerta de cero-ingreso."
  type        = string
  default     = "1h"
}

variable "growth_min_backlog" {
  description = <<-EOT
    Alerta 4: backlog minimo para que el crecimiento cuente. Guard anti-ruido:
    sin esto, ir de 1 a 2 mensajes se registra como "crecimiento sostenido".
  EOT
  type        = number
  default     = 3
}

variable "growth_duration" {
  description = "Alerta 4: cuanto debe sostenerse el crecimiento. 900s = 15 min."
  type        = string
  default     = "900s"
}

# ---------------------------------------------------------------------------
# Notificacion
# ---------------------------------------------------------------------------

variable "teams_webhook_url" {
  description = <<-EOT
    URL del flujo de Power Automate que publica en Teams.
    Dejar vacio para crear las politicas sin canal de notificacion (modo silencioso).
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_notifications" {
  description = <<-EOT
    false = las politicas se crean y evaluan, pero no notifican a nadie.
    Util para observar el comportamiento real antes de conectar Teams.
  EOT
  type        = bool
  default     = false
}
