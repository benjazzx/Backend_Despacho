# back-Despachos — Microservicio de Despachos

API REST desarrollada en Spring Boot 3 que gestiona las órdenes de despacho del sistema Innovatech Chile. Desplegada en **AWS ECS Fargate** dentro de una subred privada, con acceso expuesto únicamente a través del **Application Load Balancer (ALB)**.

---

## Tabla de contenidos

1. [Arquitectura en producción](#1-arquitectura-en-producción)
2. [Endpoints de la API](#2-endpoints-de-la-api)
3. [Variables de entorno](#3-variables-de-entorno)
4. [Contenedor Docker](#4-contenedor-docker)
5. [Pipeline CI/CD](#5-pipeline-cicd)
6. [Gestión de secretos](#6-gestión-de-secretos)
7. [Escalado automático](#7-escalado-automático)
8. [Monitoreo y logs](#8-monitoreo-y-logs)
9. [Validación funcional](#9-validación-funcional)
10. [Ejecución local](#10-ejecución-local)

---

## 1. Arquitectura en producción

```
Internet
    │  HTTPS 443
    ▼
┌─────────────────────────────────────────────────────┐
│  Application Load Balancer (ALB)                    │
│  innovatech-alb-516038279.us-east-1.elb.amazonaws.com │
│  Regla: /api/v1/despachos* → back-despachos-svc :8081 │
└──────────────────────────┬──────────────────────────┘
                           │ HTTP interno
                           ▼
            ┌──────────────────────────────┐
            │  ECS Fargate — back-despachos-svc │
            │  Cluster: innovatech-ecs-cluster │
            │  Tareas: 2–5 (autoscaling)   │
            │  Puerto: 8081                │
            │  Subred: privada us-east-1   │
            └──────────────┬───────────────┘
                           │ JDBC MySQL
                           ▼
            ┌──────────────────────────────┐
            │  Amazon RDS MySQL 8.0        │
            │  innovatech-ecs-db           │
            │  Subred privada              │
            └──────────────────────────────┘
```

**Componentes de infraestructura:**

| Recurso | Nombre / Valor |
|---|---|
| Cluster ECS | `innovatech-ecs-cluster` |
| Servicio ECS | `back-despachos-svc` |
| ECR Repository | `back-despachos` |
| Puerto de contenedor | `8081` |
| Región | `us-east-1` |
| ALB | `innovatech-alb-516038279.us-east-1.elb.amazonaws.com` |
| RDS endpoint | `innovatech-ecs-db.cyihboqkds5h.us-east-1.rds.amazonaws.com` |
| Tipo de lanzamiento | Fargate (serverless) |

**¿Por qué un microservicio separado de ventas?**

La separación en dos servicios independientes permite:
- **Despliegue independiente:** se puede actualizar despachos sin tocar ventas y viceversa.
- **Escalado independiente:** si el volumen de despachos crece, solo ese servicio escala.
- **Fallo aislado:** un error en despachos no tumba el servicio de ventas.

---

## 2. Endpoints de la API

Base path: `/api/v1/despachos`

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/api/v1/despachos` | Listar todos los despachos |
| `GET` | `/api/v1/despachos/{idDespacho}` | Obtener despacho por ID |
| `POST` | `/api/v1/despachos` | Crear nuevo despacho |
| `PUT` | `/api/v1/despachos/{idDespacho}` | Actualizar despacho (intentos, cierre) |

**Documentación interactiva (Swagger UI):**

```
https://innovatech-alb-516038279.us-east-1.elb.amazonaws.com/swagger-ui.html
```

---

## 3. Variables de entorno

La aplicación no contiene credenciales en el código ni en archivos versionados. Todas las variables sensibles se inyectan en tiempo de ejecución a través de la **ECS Task Definition** (ver sección 6).

| Variable | Descripción | Ejemplo |
|---|---|---|
| `DB_ENDPOINT` | Host del servidor RDS | `innovatech-ecs-db.cyihboqkds5h.us-east-1.rds.amazonaws.com` |
| `DB_PORT` | Puerto MySQL | `3306` |
| `DB_NAME` | Nombre de la base de datos | `despachosdb` |
| `DB_USERNAME` | Usuario de la base de datos | *(secreto)* |
| `DB_PASSWORD` | Contraseña de la base de datos | *(secreto)* |

Configuración en `application.properties`:

```properties
server.port=8081
spring.datasource.url=jdbc:mysql://${DB_ENDPOINT}:${DB_PORT}/${DB_NAME}?useSSL=false&serverTimezone=UTC&createDatabaseIfNotExist=true
spring.datasource.username=${DB_USERNAME}
spring.datasource.password=${DB_PASSWORD}
spring.jpa.hibernate.ddl-auto=update
management.endpoints.web.exposure.include=health,info
management.endpoint.health.show-details=always
spring.web.allow-cors=true
```

---

## 4. Contenedor Docker

El `Dockerfile` implementa un **build multi-stage** para separar el entorno de compilación del de producción:

```dockerfile
# Stage 1: Build — Maven compila el JAR
FROM maven:3.9-eclipse-temurin-17-alpine AS builder
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -B        # cachea dependencias
COPY src ./src
RUN mvn package -DskipTests -B          # genera target/*.jar

# Stage 2: Runtime — solo la JRE mínima
FROM eclipse-temurin:17-jre-alpine AS runtime
WORKDIR /app
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
COPY --from=builder /app/target/*.jar app.jar
RUN chown appuser:appgroup app.jar
USER appuser                            # principio de mínimo privilegio
EXPOSE 8081
ENTRYPOINT ["java", "-jar", "app.jar"]
```

**Decisiones de diseño:**

- **Multi-stage build:** La imagen final contiene únicamente la JRE (`eclipse-temurin:17-jre-alpine`, ~85MB). Maven (~500MB), el código fuente y las dependencias de compilación quedan fuera de la imagen de producción.
- **Usuario no-root (`appuser`):** Principio de mínimo privilegio. El proceso Java corre sin permisos de root; un eventual compromiso del contenedor no otorga acceso administrativo al host.
- **Caching de dependencias:** `mvn dependency:go-offline` descarga todas las dependencias antes de copiar el código fuente. Si solo cambia `src/` (y no `pom.xml`), Docker reutiliza la capa cacheada → builds ~5x más rápidos.

**Tamaño comparado:**

| Etapa | Imagen base | Tamaño aprox. |
|---|---|---|
| Builder | `maven:3.9-eclipse-temurin-17-alpine` | ~500 MB |
| Runtime final | `eclipse-temurin:17-jre-alpine` | ~85 MB |

---

## 5. Pipeline CI/CD

El archivo `.github/workflows/deploy.yml` automatiza el ciclo completo de integración y despliegue. Se activa en cada `git push` a la rama `deploy`.

```
git push origin deploy
        │
        ▼
┌────────────────────────────────────────┐
│  GitHub Actions                        │
│                                        │
│  1. Checkout del repositorio           │
│  2. Configurar AWS credentials         │
│     (ACCESS_KEY_ID + SESSION_TOKEN     │
│      desde GitHub Secrets)             │
│  3. Login a Amazon ECR                 │
│  4. docker build -t registry/back-despachos:sha │
│                  -t registry/back-despachos:latest │
│     Build context: ./Springboot-API-REST-DESPACHO │
│  5. docker push ambos tags             │
│  6. aws ecs update-service             │
│     --force-new-deployment             │
│  7. Verificar rolloutState             │
│     (COMPLETED o IN_PROGRESS = OK)     │
└────────────────────────────────────────┘
        │
        ▼
ECS Fargate descarga la nueva imagen
y reemplaza tareas gradualmente (rolling update)
```

**Variables del pipeline:**

```yaml
env:
  AWS_REGION: us-east-1
  ECR_REPOSITORY: back-despachos
  ECS_CLUSTER: innovatech-ecs-cluster
  ECS_SERVICE: back-despachos-svc
```

**¿Por qué dos tags (`sha` y `latest`)?**

- `sha` (ej. `a3f7c9d`): trazabilidad exacta; permite hacer rollback a una versión anterior con precisión.
- `latest`: la Task Definition de ECS referencia `:latest` para desplegar automáticamente la versión más reciente.

**Rolling Update — Cero downtime:**

ECS no baja las tareas activas hasta que las nuevas estén healthy. Durante el despliegue coexisten versiones antigua y nueva, garantizando que el servicio nunca quede completamente sin atender.

---

## 6. Gestión de secretos

El proyecto maneja dos capas de secretos:

### GitHub Actions Secrets

Las credenciales de AWS para que el pipeline pueda publicar en ECR y desplegar en ECS se almacenan como **GitHub Secrets** (cifrados, nunca expuestos en logs ni en el repositorio):

| Secret | Descripción |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access Key de AWS Academy |
| `AWS_SECRET_ACCESS_KEY` | Secret Access Key de AWS Academy |
| `AWS_SESSION_TOKEN` | Session Token de AWS Academy (credenciales temporales STS) |

**¿Por qué Session Token?** AWS Academy genera credenciales temporales (AWS STS) que expiran cada ~4 horas. El uso de GitHub Secrets permite actualizarlas sin modificar el código del pipeline ni exponer valores sensibles en el historial de Git.

### ECS Task Definition — Variables de entorno

Las credenciales de base de datos (`DB_USERNAME`, `DB_PASSWORD`) y el endpoint RDS se configuran directamente en la Task Definition de ECS. **Nunca están en el repositorio Git, Dockerfile, ni logs del pipeline.**

```
GitHub Secrets → solo disponibles dentro del runner de GitHub Actions
ECS Task Def env vars → solo disponibles dentro del contenedor en ejecución
```

Esta separación asegura que las credenciales no se filtren aunque alguien obtenga acceso al código fuente o a los artefactos de build.

---

## 7. Escalado automático

Application Auto Scaling está configurado sobre el servicio ECS para ajustar la capacidad según la demanda:

| Parámetro | Valor |
|---|---|
| Mínimo de tareas | 2 |
| Máximo de tareas | 5 |
| Servicio | `back-despachos-svc` |

**Alta disponibilidad con mínimo 2 tareas:** Si una tarea falla o una zona de disponibilidad tiene un incidente, siempre hay al menos otra tarea activa. ECS distribuye las tareas en diferentes zonas de disponibilidad automáticamente.

**¿Por qué máximo 5?** Límite operativo para el entorno académico (AWS Academy tiene cuotas de recursos). En producción, el máximo se definiría en base a benchmarks de carga.

---

## 8. Monitoreo y logs

### CloudWatch Container Insights

Container Insights está habilitado en el cluster `innovatech-ecs-cluster`. Permite visualizar en tiempo real:

- **CPU Utilization** por servicio y por tarea
- **Memory Utilization** por servicio y por tarea
- **Network I/O** (bytes enviados/recibidos por tarea)
- **Task count** (tareas running vs desired)

```bash
# Verificar que Container Insights está habilitado
aws ecs describe-clusters \
  --clusters innovatech-ecs-cluster \
  --query "clusters[0].settings"
```

### Logs del contenedor

Los logs de stdout del proceso Java se envían automáticamente a **CloudWatch Logs**:

```
Log Group: /ecs/back-despachos
Log Stream: ecs/back-despachos/<task-id>
```

### Health Check — Spring Actuator

Spring Boot Actuator expone el endpoint de salud utilizado por el ALB:

```
GET /actuator/health
```

Respuesta esperada:

```json
{
  "status": "UP",
  "components": {
    "db": { "status": "UP" },
    "diskSpace": { "status": "UP" }
  }
}
```

El ALB verifica este endpoint periódicamente. Si una tarea responde con error o no responde, ECS la reemplaza automáticamente por una nueva.

---

## 9. Validación funcional

### Verificar que el servicio está operativo

```bash
# Health check via ALB
curl https://innovatech-alb-516038279.us-east-1.elb.amazonaws.com/actuator/health

# Listar despachos
curl https://innovatech-alb-516038279.us-east-1.elb.amazonaws.com/api/v1/despachos

# Crear despacho
curl -X POST https://innovatech-alb-516038279.us-east-1.elb.amazonaws.com/api/v1/despachos \
  -H "Content-Type: application/json" \
  -d '{"idCompra": 1, "fechaDespacho": "2026-06-18", "patenteCamion": "ABCD12"}'

# Actualizar despacho (cerrar / registrar intento)
curl -X PUT https://innovatech-alb-516038279.us-east-1.elb.amazonaws.com/api/v1/despachos/1 \
  -H "Content-Type: application/json" \
  -d '{"intento": 2, "despachado": true}'
```

### Verificar estado del servicio ECS

```bash
aws ecs describe-services \
  --cluster innovatech-ecs-cluster \
  --services back-despachos-svc \
  --query "services[0].{Running:runningCount,Desired:desiredCount,Status:status}" \
  --output table
```

---

## 10. Ejecución local

Requiere Java 17+ y Maven 3.9+.

### Sin Docker

```bash
cd Springboot-API-REST-DESPACHO

# Configurar variables de entorno (base de datos local)
export DB_ENDPOINT=localhost
export DB_PORT=3306
export DB_NAME=despachosdb
export DB_USERNAME=root
export DB_PASSWORD=

mvn spring-boot:run
```

API disponible en `http://localhost:8081/api/v1/despachos`

### Con Docker

```bash
cd Springboot-API-REST-DESPACHO

docker build -t back-despachos:local .

docker run -p 8081:8081 \
  -e DB_ENDPOINT=host.docker.internal \
  -e DB_PORT=3306 \
  -e DB_NAME=despachosdb \
  -e DB_USERNAME=root \
  -e DB_PASSWORD= \
  back-despachos:local
```

### Con Docker Compose (stack completo)

```bash
# Desde la raíz del repositorio
docker compose up --build
```

---

## Tecnologías

| Tecnología | Versión | Rol |
|---|---|---|
| Spring Boot | 3.4.4 | Framework principal |
| Spring Data JPA | — | ORM sobre MySQL |
| Spring Boot Actuator | — | Health checks y métricas |
| springdoc-openapi | — | Documentación Swagger |
| MySQL Connector/J | — | Driver JDBC |
| Java | 17 | Runtime |
| Maven | 3.9 | Build y dependencias |
| Docker | multi-stage | Empaquetado |
| GitHub Actions | — | CI/CD |
| Amazon ECS Fargate | — | Ejecución en la nube |
| Amazon ECR | — | Registro de imágenes |
| Amazon RDS | MySQL 8.0 | Base de datos |
| ALB | — | Balanceo y SSL termination |
