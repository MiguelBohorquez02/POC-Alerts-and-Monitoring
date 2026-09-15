# POC-Alerts-and-Monitoring

Alertas Pub/Sub → Teams. Cuatro alert policies de Cloud Monitoring sobre
subscriptions de Pub/Sub, definidas como codigo (Terraform), cubriendo
"Pillar 2: Queue & Traffic Dynamics".

## Qué detecta cada alerta

| Politica | Umbral | Que significa |
|---|---|---|
| `oldest_unacked_message_age` | > 15 min | Consumer caido o atascado |
| `backlog_depth` | >= 10 msg por 10 min | Consumer sin capacidad |
| `zero_ingress` | 1h sin publicaciones | Scheduler dejo de publicar |
| `queue_growth_rate` | ingress > drain por 15 min | Degradacion parcial (aviso temprano) |

## Decisiones de diseño

**Solo produccion.** Alertar sobre dev/sit/uat genera ruido constante: en esos
ambientes es normal que las colas se atasquen.

**Sin colas de error.** En una DLQ la logica se invierte — cualquier mensaje ya
es una anomalia, y que quede sin consumir puede ser lo esperado. Corresponden al
Pilar 4 (DLQ Accumulation), no a estas cuatro.

**Cero-ingreso cubre TODOS los topics de prod, descubiertos solos.** Alcance
confirmado con el stakeholder: no es un topic puntual del Scheduler, es
cualquier topic de prod que se quede en silencio. Los topics se descubren via
`gcloud` en cada `plan`/`apply` (`data.external.pubsub_topics` en `main.tf`) y
se filtran con `topic_include_regex`/`topic_exclude_regex` — no hay una lista
para mantener a mano.

**Simplificacion consciente en cero-ingreso.** El pedido real era comparar
cada topic contra su propio promedio historico (avisar si un topic que
normalmente publica todos los dias deja de hacerlo). Eso es deteccion de
anomalia por topic; lo que hay implementado es una ventana de silencio fija
(`zero_ingress_window`) igual para todos. Cubre la mayor parte del valor con
una fraccion del esfuerzo — la version con baseline por topic queda pendiente
si hace falta mas precision.

**Una politica por topic en cero-ingreso.** `absent_over_time` solo devuelve algo
si ninguna serie del selector tiene datos. Con un regex de varios topics, uno
silencioso queda tapado por los demas.

**Crecimiento = derivada del backlog.** Por definicion `d(backlog)/dt = ingress −
drain`, asi que no hace falta comparar dos metricas ni unir labels de topic con
labels de subscription.

**Notificaciones apagadas por defecto.** Las politicas evaluan y registran
incidentes sin avisar a nadie. Permite observar el comportamiento real durante la
calibracion sin llenar Teams.

## Uso

```bash
cp terraform.tfvars.example terraform.tfvars
# editar terraform.tfvars

gcloud auth application-default login

terraform init
terraform validate
terraform plan
terraform apply
```

## Pendientes

- [x] Confirmar el alcance real de las subscriptions (account-customer-v1 prod)
- [x] Crear el flujo de Power Automate y conectarlo a Teams
- [x] Confirmar el alcance de cero-ingreso (todos los topics de prod, via regex)
- [ ] Contar cuantos topics matchean `topic_include_regex` antes del primer `apply`
      de este cambio (puede ser una cantidad grande de politicas nuevas):
      `gcloud pubsub topics list --format="value(name)" | sed 's#.*/##' | grep -E '(^|-)prod(-|$)' | grep -v -i error | wc -l`
- [ ] Calibrar umbrales con ~1 semana de datos reales, incluyendo `zero_ingress_window`
- [ ] Confirmar si los topics de prod publican 24/7 (si alguno no, la alerta de
      cero-ingreso necesita snooze programado o exclusion puntual)
- [ ] Evaluar si hace falta la version con baseline historico por topic (en vez
      de ventana fija) para cero-ingreso
