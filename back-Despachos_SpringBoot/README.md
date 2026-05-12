# Back Despachos — Microservicio de Gestión de Despachos

API REST desarrollada con Spring Boot que gestiona las órdenes de despacho del sistema Innovatech Chile. Es el segundo microservicio del backend, desplegado en AWS EC2 dentro de una subred privada. Solo es accesible desde el frontend, nunca directamente desde Internet.

---

## ¿Qué hace este servicio?

Permite crear, consultar, actualizar y cerrar órdenes de despacho. El frontend lo consume para:
- Crear un despacho nuevo a partir de una venta (asignando fecha, patente del camión)
- Listar todos los despachos activos
- Cerrar un despacho marcándolo como `despachado = true` y registrando los intentos de entrega

---

## Endpoints

| Método | Ruta | Descripción |
|---|---|---|
| GET | /api/v1/despachos | Listar todos los despachos |
| GET | /api/v1/despachos/{id} | Obtener despacho por ID |
| POST | /api/v1/despachos | Crear nuevo despacho |
| PUT | /api/v1/despachos/{id} | Actualizar despacho |
| DELETE | /api/v1/despachos/{id} | Eliminar despacho |

Swagger UI disponible en: `http://localhost:8081/swagger-ui.html`

---

## Tecnologías

- Java 17
- Spring Boot 3.4.4
- Spring Data JPA + Hibernate
- MySQL 8.0
- Docker (multi-stage build)

---

## Variables de entorno

| Variable | Descripción | Ejemplo |
|---|---|---|
| DB_ENDPOINT | Host del servidor MySQL | mysql / IP EC2 |
| DB_PORT | Puerto MySQL | 3306 |
| DB_NAME | Nombre de la base de datos | despachos_db |
| DB_USERNAME | Usuario MySQL | innovatech |
| DB_PASSWORD | Contraseña MySQL | tu_password |

---

## Decisiones arquitectónicas

### ¿Por qué Docker con multi-stage build?
El Dockerfile usa dos etapas separadas:
- **Stage 1 (builder):** imagen `maven:3.9-eclipse-temurin-17-alpine` descarga dependencias y compila el JAR con `mvn package -DskipTests`.
- **Stage 2 (runtime):** imagen `eclipse-temurin:17-jre-alpine`, imagen mínima que solo contiene el JRE. No incluye Maven, código fuente ni dependencias de compilación.

**Beneficio:** la imagen final es ~70% más pequeña que una imagen de una sola etapa, y no expone herramientas innecesarias en producción.

### ¿Por qué usuario no root?
```dockerfile
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser
```
El contenedor corre con un usuario sin privilegios. Si la aplicación fuera comprometida, el atacante no tendría permisos de root dentro del contenedor. Es el principio de mínimo privilegio aplicado a contenedores.

### ¿Por qué puerto 8081 y no 8080?
Este microservicio corre en el puerto 8081 para diferenciarse del microservicio de ventas (8080). En el `docker-compose.yml` ambos servicios están en la misma red interna (`backend_network`) y el frontend los alcanza por nombre de servicio. El puerto solo importa para el mapeo al host en desarrollo local.

### ¿Por qué named volume y no bind mount para MySQL?
Se usa un **named volume** (`innovatech_mysql_data`) en lugar de un bind mount porque:
- El named volume es gestionado completamente por Docker, sin dependencia de la estructura de directorios del host
- Es más portable: funciona igual en Linux, Windows y Mac
- En AWS EC2, no hay garantía de que exista una ruta específica en el host
- El bind mount es útil cuando necesitas acceder directamente a los archivos desde el host (por ejemplo, para backups manuales), lo cual no es el caso aquí

### ¿Por qué el `init.sql` otorga permisos explícitamente?
```sql
GRANT ALL PRIVILEGES ON despachos_db.* TO 'innovatech'@'%';
```
Cuando Docker crea el usuario MySQL con `MYSQL_USER`, solo le otorga acceso a la base de datos especificada en `MYSQL_DATABASE`. Como no se define `MYSQL_DATABASE` (porque son dos bases distintas para dos microservicios), el usuario no tiene acceso a ninguna. El `init.sql` crea las bases y otorga los permisos necesarios.

### ¿Por qué dos bases de datos separadas?
Cada microservicio tiene su propia base de datos (`ventas_db` y `despachos_db`). Esto sigue el principio de **base de datos por servicio** de la arquitectura de microservicios:
- Los servicios son independientes: si uno cae, el otro sigue funcionando
- Los esquemas no se acoplan: un cambio en la tabla de ventas no afecta a despachos
- En EC2, cada servicio puede conectarse a su propia instancia RDS en el futuro

---

## Cómo ejecutar localmente

### Con Docker (recomendado)

Desde la raíz del proyecto semestral:

```bash
cp .env.example .env   # editar con tus valores
docker compose up --build
```

Servicio disponible en `http://localhost:8081`

### Sin Docker

Requiere MySQL corriendo localmente con la base de datos `despachos_db` creada:

```bash
./mvnw spring-boot:run
```

---

## Pipeline CI/CD

El archivo `.github/workflows/deploy.yml` automatiza el despliegue al hacer `git push` sobre la rama `deploy`:

1. **Build:** compila la imagen Docker usando el Dockerfile multi-stage
2. **Push:** publica la imagen en Docker Hub como `{usuario}/back-despachos:latest`
3. **Deploy:** conecta por SSH a la instancia EC2, baja la nueva imagen y reinicia el contenedor

### Secrets requeridos en GitHub

| Secret | Descripción |
|---|---|
| DOCKERHUB_USERNAME | Usuario de Docker Hub |
| DOCKERHUB_TOKEN | Token de acceso Docker Hub |
| EC2_HOST | IP de la instancia EC2 backend |
| EC2_USER | Usuario SSH (ec2-user o ubuntu) |
| EC2_SSH_KEY | Contenido del archivo .pem |
| DB_ENDPOINT | IP o hostname del MySQL en EC2 |
| DB_USERNAME | Usuario MySQL |
| DB_PASSWORD | Contraseña MySQL |

---

## Estructura del proyecto

```
Springboot-API-REST-DESPACHO/
├── src/main/java/com/citt/
│   ├── controller/        # DespachoController — endpoints REST
│   ├── persistence/
│   │   ├── entity/        # Despacho — entidad JPA
│   │   ├── repository/    # DespachoRepository — acceso a datos
│   │   └── services/      # DespachoService + DespachoServiceImpl
│   ├── exceptions/        # Manejo de errores 404
│   └── config/            # CORS + OpenAPI/Swagger
├── src/main/resources/
│   └── application.properties
├── Dockerfile
└── pom.xml
```
