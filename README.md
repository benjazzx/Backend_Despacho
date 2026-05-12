# Innovatech Chile — Sistema de Gestión de Despachos

Sistema de microservicios desarrollado para gestionar ventas y órdenes de despacho de Innovatech Chile. Compuesto por un frontend React y dos microservicios Spring Boot con base de datos MySQL compartida, todo contenedorizado con Docker y desplegado en AWS EC2.

---

## Arquitectura general

```
Internet
    │
    ▼
┌──────────────────────────┐
│   EC2 Pública (Frontend) │  ← Solo este es accesible desde Internet
│   nginx (puerto 80)      │
│   React SPA              │
└────────────┬─────────────┘
             │ HTTP (API calls)
             ▼
┌──────────────────────────────────────────┐
│         EC2 Privada (Backend)            │
│                                          │
│  ┌─────────────────┐  ┌───────────────┐  │
│  │  back-ventas    │  │ back-despachos│  │
│  │  Spring Boot    │  │ Spring Boot   │  │
│  │  puerto 8080    │  │ puerto 8081   │  │
│  └────────┬────────┘  └───────┬───────┘  │
│           └──────────┬────────┘          │
│                      ▼                   │
│              ┌──────────────┐            │
│              │  MySQL 8.0   │            │
│              │  ventas_db   │            │
│              │  despachos_db│            │
│              └──────────────┘            │
└──────────────────────────────────────────┘
```

- El **frontend** corre en una instancia EC2 pública (subred pública). Es el único componente accesible desde Internet.
- El **backend** corre en una instancia EC2 privada (subred privada). Solo acepta conexiones desde el frontend.
- Los Security Groups de AWS garantizan este aislamiento.

---

## Servicios

| Servicio | Tecnología | Puerto | Descripción |
|---|---|---|---|
| `back-ventas` | Spring Boot 3 + JPA | 8080 | CRUD de órdenes de compra |
| `back-despachos` | Spring Boot 3 + JPA | 8081 | CRUD de órdenes de despacho |
| `mysql` | MySQL 8.0 | 3306 (interno) | Base de datos (ventas_db + despachos_db) |
| `frontend` | React + nginx | 80 | Interfaz de usuario |

Documentación detallada de cada microservicio:
- [back-ventas/README.md](back-Ventas_SpringBoot/README.md)
- [back-despachos/README.md](back-Despachos_SpringBoot/README.md)

---

## Cómo ejecutar localmente (stack completo)

### Prerrequisitos
- Docker Desktop instalado y en ejecución
- La imagen del frontend publicada en Docker Hub (ver pipeline CI/CD del repo frontend)

### Pasos

```bash
# 1. Copiar plantilla de variables de entorno
cp .env.example .env

# 2. Editar .env con tus valores
#    - DOCKERHUB_USERNAME: tu usuario de Docker Hub
#    - DB_USERNAME / DB_PASSWORD: credenciales MySQL
#    - MYSQL_ROOT_PASSWORD: contraseña root MySQL

# 3. Levantar el stack
docker compose up -d

# 4. Verificar que todos los servicios estén healthy
docker compose ps
```

**Servicios disponibles:**
- Frontend: `http://localhost`
- API Ventas (Swagger): `http://localhost:8080/swagger-ui.html`
- API Despachos (Swagger): `http://localhost:8081/swagger-ui.html`

> **Nota:** La imagen del frontend (`${DOCKERHUB_USERNAME}/frontend-despacho:latest`) debe estar publicada en Docker Hub. Si quieres buildear el frontend localmente, clona también el repositorio del frontend y usa su propio `docker-compose.yml`.

### Apagar y eliminar datos

```bash
docker compose down          # Apaga contenedores, conserva datos
docker compose down -v       # Apaga contenedores y ELIMINA el volumen MySQL
```

---

## Variables de entorno

Copiar `.env.example` a `.env` y completar:

| Variable | Descripción | Ejemplo |
|---|---|---|
| `MYSQL_ROOT_PASSWORD` | Contraseña root MySQL | `root_password` |
| `DB_USERNAME` | Usuario MySQL para los microservicios | `innovatech` |
| `DB_PASSWORD` | Contraseña del usuario MySQL | `tu_password` |
| `DOCKERHUB_USERNAME` | Usuario de Docker Hub (para pull imagen frontend) | `benjazzx` |
| `VITE_VENTAS_URL` | URL del backend ventas (solo informativa en este compose) | `http://localhost:8080` |
| `VITE_DESPACHOS_URL` | URL del backend despachos (solo informativa en este compose) | `http://localhost:8081` |

---

## Persistencia de datos

Se utiliza un **named volume** llamado `innovatech_mysql_data` montado en `/var/lib/mysql` del contenedor MySQL.

**¿Por qué named volume y no bind mount?**
- El named volume es gestionado completamente por Docker, sin depender de la estructura de directorios del host.
- Es portable: funciona igual en Linux, macOS y Windows.
- En AWS EC2 no hay garantía de que exista una ruta específica en el host.
- El bind mount es útil cuando se necesita acceder directamente a los archivos desde el host (por ejemplo, para backups manuales), lo cual no es requerido aquí.

---

## Inicialización de la base de datos

El archivo `init.sql` se ejecuta automáticamente cuando MySQL arranca por primera vez (mediante el mecanismo de `/docker-entrypoint-initdb.d/`):

```sql
CREATE DATABASE IF NOT EXISTS ventas_db;
CREATE DATABASE IF NOT EXISTS despachos_db;
GRANT ALL PRIVILEGES ON ventas_db.* TO 'innovatech'@'%';
GRANT ALL PRIVILEGES ON despachos_db.* TO 'innovatech'@'%';
FLUSH PRIVILEGES;
```

**¿Por qué los GRANT explícitos?** La variable `MYSQL_USER` de Docker solo otorga permisos sobre la base definida en `MYSQL_DATABASE`. Como se definen dos bases de datos distintas y no se usa `MYSQL_DATABASE`, el usuario `innovatech` quedaría sin permisos sobre ninguna. El `init.sql` resuelve esto.

---

## Estructura del repositorio

```
proyecto-semestral/
├── back-Ventas_SpringBoot/
│   ├── .github/workflows/deploy.yml    # Pipeline CI/CD back-ventas
│   ├── Springboot-API-REST/
│   │   ├── Dockerfile                  # Multi-stage build
│   │   ├── pom.xml
│   │   └── src/
│   └── README.md                       # Documentación microservicio ventas
├── back-Despachos_SpringBoot/
│   ├── .github/workflows/deploy.yml    # Pipeline CI/CD back-despachos
│   ├── Springboot-API-REST-DESPACHO/
│   │   ├── Dockerfile                  # Multi-stage build
│   │   ├── pom.xml
│   │   └── src/
│   └── README.md                       # Documentación microservicio despachos
├── docker-compose.yml                  # Stack completo (backend + frontend)
├── init.sql                            # Inicialización MySQL
├── .env.example                        # Plantilla de variables de entorno
├── .gitignore
└── README.md                           # Este archivo
```

---

## Pipelines CI/CD

Cada microservicio tiene su propio pipeline en `.github/workflows/deploy.yml`. Todos comparten la misma estructura:

1. **Trigger:** push a la rama `deploy`
2. **Build:** construye la imagen Docker multi-stage
3. **Push:** publica en Docker Hub como `{usuario}/back-ventas:latest` o `{usuario}/back-despachos:latest`
4. **Deploy:** conecta por SSH a la instancia EC2 privada, descarga la nueva imagen y reinicia el contenedor

### Secrets requeridos (por microservicio)

| Secret | Descripción |
|---|---|
| `DOCKERHUB_USERNAME` | Usuario de Docker Hub |
| `DOCKERHUB_TOKEN` | Token de acceso Docker Hub |
| `EC2_HOST` | IP de la instancia EC2 backend |
| `EC2_USER` | Usuario SSH (`ec2-user` o `ubuntu`) |
| `EC2_SSH_KEY` | Contenido del archivo `.pem` |
| `DB_ENDPOINT` | IP o hostname del MySQL en EC2 |
| `DB_USERNAME` | Usuario MySQL |
| `DB_PASSWORD` | Contraseña MySQL |

---

## Despliegue en AWS EC2

### Arquitectura de red AWS

- **EC2 Frontend** (subred pública): solo expone el puerto 80. Security Group permite tráfico HTTP/HTTPS desde `0.0.0.0/0`.
- **EC2 Backend** (subred privada): expone puertos 8080 y 8081. Security Group solo permite tráfico desde la IP/SG del frontend. MySQL (3306) solo acepta conexiones internas.

### Flujo de despliegue

```
git push origin deploy
        │
        ▼
GitHub Actions (runner Ubuntu)
        │
        ├─ docker build (multi-stage)
        ├─ docker push → Docker Hub
        └─ SSH a EC2 → docker pull → docker stop → docker run
```
