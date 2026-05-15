# Back Despachos — Microservicio de Gestión de Despachos

API REST desarrollada con Spring Boot 3 que gestiona las órdenes de despacho del sistema Innovatech Chile. Es el segundo microservicio del backend, desplegado en AWS EC2 dentro de una subred **privada** — no es accesible directamente desde Internet.

---

## ¿Qué hace este servicio?

Permite crear, consultar, actualizar y cerrar órdenes de despacho. El frontend lo consume para:
- Crear un despacho nuevo a partir de una venta (asignando fecha, patente del camión)
- Listar todos los despachos activos
- Cerrar un despacho marcándolo como despachado y registrando los intentos de entrega

Swagger UI disponible en: `http://localhost:8081/swagger-ui.html`

---

## Endpoints

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/api/v1/despachos` | Listar todos los despachos |
| GET | `/api/v1/despachos/{id}` | Obtener despacho por ID |
| POST | `/api/v1/despachos` | Crear nuevo despacho |
| PUT | `/api/v1/despachos/{id}` | Actualizar despacho |
| DELETE | `/api/v1/despachos/{id}` | Eliminar despacho |

---

## Tecnologías

| Tecnología | Versión | Rol |
|---|---|---|
| Java | 17 | Lenguaje |
| Spring Boot | 3.4.4 | Framework principal |
| Spring Data JPA | 3.4.4 | Acceso a base de datos |
| Hibernate | (incluido en JPA) | ORM |
| MySQL | 8.0 | Base de datos |
| SpringDoc OpenAPI | 2.7.0 | Swagger UI |
| Lombok | 1.18 | Reducción de boilerplate |
| Docker | multi-stage | Empaquetado |
| Maven | 3.9 | Gestión de dependencias |

---

## Arquitectura en producción (AWS)

```
Internet
    │
    ▼
┌──────────────────────────────────────────┐
│  ec2-web  (subred pública)               │
│  Elastic IP: 52.73.73.226               │
│  Contenedor: frontend (nginx)            │
│  nginx hace proxy → 10.0.9.120:8081  ───┼──┐
└──────────────────────────────────────────┘  │
                                              │ VPC privada
    ┌─────────────────────────────────────────▼┐
    │  ec2-app  (10.0.9.120, privada)          │
    │  Contenedor: back-ventas  :8080          │
    │  Contenedor: back-despachos :8081  ◄─────┤
    └──────────────┬───────────────────────────┘
                   │
    ┌──────────────▼──────────────┐
    │  ec2-datos  (10.0.7.237)    │
    │  MySQL 8.0  :3306           │
    │  Base: despachos_db         │
    └─────────────────────────────┘
```

`ec2-app` no tiene IP pública. Solo es accesible desde dentro de la VPC a través de `ec2-web`.

---

## Estructura del proyecto

```
Springboot-API-REST-DESPACHO/
├── src/main/java/com/citt/
│   ├── controller/        # DespachoController — endpoints REST
│   ├── persistence/
│   │   ├── entity/        # Despacho — entidad JPA (tabla despachos)
│   │   ├── repository/    # DespachoRepository — CRUD con Spring Data
│   │   └── services/      # DespachoService + DespachoServiceImpl
│   ├── exceptions/        # Manejo de errores 404
│   └── config/            # CORS + OpenAPI/Swagger
├── src/main/resources/
│   └── application.properties  # Variables DB_ENDPOINT, DB_NAME, etc.
├── Dockerfile             # Multi-stage: maven builder + JRE runtime
└── pom.xml                # Dependencias Maven
```

---

## Decisiones arquitectónicas

### ¿Por qué Docker con multi-stage build?

```dockerfile
# Stage 1: Build — imagen con Maven para compilar
FROM maven:3.9-eclipse-temurin-17-alpine AS builder
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -B     # descarga dependencias (cache)
COPY src ./src
RUN mvn package -DskipTests -B       # compila el JAR

# Stage 2: Runtime — imagen mínima solo con JRE
FROM eclipse-temurin:17-jre-alpine AS runtime
WORKDIR /app
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
COPY --from=builder /app/target/*.jar app.jar
RUN chown appuser:appgroup app.jar
USER appuser
EXPOSE 8081
ENTRYPOINT ["java", "-jar", "app.jar"]
```

- **Stage 1 (builder):** `maven:3.9-eclipse-temurin-17-alpine` (~500MB) compila el JAR. Esta imagen nunca llega a producción.
- **Stage 2 (runtime):** `eclipse-temurin:17-jre-alpine` (~180MB) solo contiene el JRE mínimo para ejecutar el JAR. Sin Maven, sin código fuente.

Copiar `pom.xml` antes que el código fuente permite que Docker reutilice la capa de dependencias como **caché** si el código cambia pero las dependencias no.

### ¿Por qué puerto 8081 y no 8080?

El microservicio de ventas ya ocupa el puerto 8080 en `ec2-app`. Ambos contenedores corren en la misma instancia EC2, por lo que deben usar puertos distintos en el host. El nginx del frontend distingue entre los dos servicios por el path:
- `/api/v1/ventas` → proxy a `:8080` (back-ventas)
- `/api/v1/despachos` → proxy a `:8081` (back-despachos)

### ¿Por qué usuario no root en el contenedor?

```dockerfile
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser
```

Por defecto los contenedores Docker corren como root. Corriendo como `appuser` (sin privilegios), si la aplicación fuera comprometida el atacante no tendría control total del contenedor ni del host. Es el principio de **mínimo privilegio**.

### ¿Por qué base de datos separada de back-ventas?

Este servicio usa `despachos_db` y back-ventas usa `ventas_db` — dos bases de datos independientes en la misma instancia MySQL. Esto sigue el principio de **base de datos por servicio** de la arquitectura de microservicios:

- Los servicios son independientes: si uno cae, el otro sigue funcionando
- Los esquemas no se acoplan: un cambio en la tabla de ventas no afecta a despachos
- Permite migrar cada base de datos a su propia instancia RDS en el futuro sin cambiar código

### ¿Por qué `ddl-auto=update`?

En `application.properties`:
```properties
spring.jpa.hibernate.ddl-auto=update
```

Hibernate crea y actualiza las tablas automáticamente al iniciar. En un entorno de evaluación/desarrollo no se requieren scripts SQL manuales. En producción real se usaría `validate` con migraciones controladas (Flyway o Liquibase).

### ¿Por qué variables de entorno para la base de datos?

```properties
spring.datasource.url=jdbc:mysql://${DB_ENDPOINT}:${DB_PORT}/${DB_NAME}?...
spring.datasource.username=${DB_USERNAME}
spring.datasource.password=${DB_PASSWORD}
```

Las credenciales nunca se hardcodean. Se pasan como variables de entorno en runtime, inyectadas desde los **secrets** cifrados de GitHub Actions. Nunca aparecen en logs ni en el código.

---

## Variables de entorno

| Variable | Descripción | Ejemplo producción |
|---|---|---|
| `DB_ENDPOINT` | Hostname o IP del servidor MySQL | `10.0.7.237` (ec2-datos) |
| `DB_PORT` | Puerto MySQL | `3306` |
| `DB_NAME` | Nombre de la base de datos | `despachos_db` |
| `DB_USERNAME` | Usuario MySQL | valor en secret |
| `DB_PASSWORD` | Contraseña MySQL | valor en secret |

---

## Pipeline CI/CD

El archivo `.github/workflows/deploy.yml` automatiza el despliegue al hacer `git push` sobre la rama `deploy`:

```
git push → GitHub Actions → Docker Hub → ec2-app (vía SSH proxy)
```

### Pasos del pipeline

```yaml
1. Checkout del repositorio
2. Login a Docker Hub (benjazzx)
3. Build y Push imagen Docker
   - Contexto: ./Springboot-API-REST-DESPACHO
   - Publica benjazzx/back-despachos:latest en Docker Hub
4. Despliegue en ec2-app (subred privada, IP 10.0.9.120)
   - Conexión SSH a través de ec2-web como bastion (proxy)
   - docker pull  → descarga nueva imagen
   - docker stop  → para contenedor anterior
   - docker rm    → elimina contenedor anterior
   - docker run   → inicia con variables de entorno DB_*
```

### Patrón bastion (SSH proxy) — decisión clave

`ec2-app` está en una subred **privada** sin IP pública. Para que GitHub Actions pueda conectarse, debe hacer SSH primero a `ec2-web` (subred pública, Elastic IP 52.73.73.226) y desde ahí saltar internamente a `ec2-app`:

```yaml
- uses: appleboy/ssh-action@v1
  with:
    host: ${{ secrets.EC2_HOST }}           # IP privada de ec2-app: 10.0.9.120
    username: ${{ secrets.EC2_USER }}
    key: ${{ secrets.EC2_SSH_KEY }}
    proxy_host: ${{ secrets.EC2_PROXY_HOST }}  # Elastic IP de ec2-web: 52.73.73.226
    proxy_username: ${{ secrets.EC2_USER }}
    proxy_key: ${{ secrets.EC2_SSH_KEY }}
```

`appleboy/ssh-action` implementa un **SSH ProxyCommand** (jump host): abre un túnel SSH hacia `ec2-web` y desde ese túnel abre una segunda conexión SSH hacia `ec2-app`. La instancia privada nunca es accesible directamente desde Internet.

### ¿Por qué la misma clave `.pem` para ambas instancias?

En AWS Academy, la misma clave `labsuser.pem` sirve para todas las instancias del laboratorio. Si el laboratorio se reinicia, la clave **cambia** — hay que actualizar el secret `EC2_SSH_KEY` en GitHub:

```bash
cat labsuser.pem | gh secret set EC2_SSH_KEY --repo benjazzx/Backend_Despacho
```

La Elastic IP (52.73.73.226) NO cambia al reiniciar — solo la clave SSH cambia.

### Secrets requeridos en GitHub

| Secret | Descripción |
|---|---|
| `DOCKERHUB_USERNAME` | Usuario de Docker Hub (`benjazzx`) |
| `DOCKERHUB_TOKEN` | Token de acceso Docker Hub |
| `EC2_HOST` | IP privada de ec2-app (`10.0.9.120`) |
| `EC2_PROXY_HOST` | Elastic IP de ec2-web (`52.73.73.226`) |
| `EC2_USER` | Usuario SSH (`ec2-user`) |
| `EC2_SSH_KEY` | Contenido del archivo `.pem` de AWS Academy |
| `DB_ENDPOINT` | IP de ec2-datos (`10.0.7.237`) |
| `DB_USERNAME` | Usuario MySQL |
| `DB_PASSWORD` | Contraseña MySQL |

---

## Cómo ejecutar localmente con Docker Compose

El `docker-compose.yml` levanta MySQL + back-despachos en un solo comando. MySQL persiste sus datos en el volumen nombrado `despachos_mysql_data`.

```bash
# Levantar ambos servicios (MySQL + Spring Boot)
docker compose up --build

# En segundo plano
docker compose up --build -d
```

Servicio disponible en `http://localhost:8081`

### ¿Por qué un volumen nombrado para MySQL?

```yaml
volumes:
  despachos_mysql_data:
    driver: local
```

Sin volumen, los datos de MySQL se pierden al hacer `docker compose down`. Con el volumen nombrado `despachos_mysql_data`, Docker persiste los archivos de la base de datos en el host. Al volver a levantar el stack, MySQL recupera todos los datos anteriores.

Diferencia clave:
- **Bind mount** (`./data:/var/lib/mysql`): mapea a una carpeta específica del host — depende del sistema de archivos del desarrollador.
- **Volumen nombrado** (`despachos_mysql_data:/var/lib/mysql`): Docker gestiona el almacenamiento internamente — portátil, funciona igual en cualquier máquina.

### ¿Por qué `depends_on` con `healthcheck`?

```yaml
depends_on:
  mysql:
    condition: service_healthy
```

Spring Boot falla al iniciar si MySQL aún no está listo. El `healthcheck` ejecuta `mysqladmin ping` cada 10 segundos y Docker Compose solo arranca `back-despachos` cuando MySQL responde correctamente.

### ¿Por qué el puerto MySQL es 3307 en el host?

back-ventas ya expone MySQL en el puerto `3306` del host. Si ambos compose se ejecutan en la misma máquina de desarrollo, habría conflicto de puertos. back-despachos usa `3307:3306` para evitarlo — dentro del contenedor MySQL sigue siendo 3306.

---

## Cómo ejecutar localmente (sin Docker)

Requiere MySQL corriendo localmente con la base de datos `despachos_db` creada.

```bash
cd Springboot-API-REST-DESPACHO
./mvnw spring-boot:run \
  -Dspring-boot.run.jvmArguments="-DDB_ENDPOINT=localhost -DDB_PORT=3306 -DDB_NAME=despachos_db -DDB_USERNAME=root -DDB_PASSWORD=password"
```

Servicio disponible en `http://localhost:8081`
