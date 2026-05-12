CREATE DATABASE IF NOT EXISTS ventas_db;
CREATE DATABASE IF NOT EXISTS despachos_db;
GRANT ALL PRIVILEGES ON ventas_db.* TO 'innovatech'@'%';
GRANT ALL PRIVILEGES ON despachos_db.* TO 'innovatech'@'%';
FLUSH PRIVILEGES;
