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

## Pendientes antes de activar notificaciones

- [ ] Confirmar el alcance real (todas las prod de account-customer-v1, o solo el flujo de emails)
- [ ] Llenar `monitored_topics` con los topics donde publica el Scheduler
- [ ] Calibrar umbrales con ~1 semana de datos reales
- [ ] Confirmar si el Scheduler corre 24/7 (si no, la alerta de cero-ingreso necesita snooze programado)
- [ ] Crear el flujo de Power Automate y asignarle co-propietarios
