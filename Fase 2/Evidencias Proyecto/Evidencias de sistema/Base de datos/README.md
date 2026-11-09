# Evidencias de sistema · Base de datos

| Archivo | Contenido |
|---|---|
| HurryUp_esquema_base_de_datos.sql | Esquema de PostgreSQL (solo estructura, sin datos): 83 tablas con llaves primarias, foráneas e índices. Se obtuvo con `pg_dump --schema-only`. |
| Modelo_Datos_HurryUp.png / .svg | Diagrama del núcleo del modelo de datos (12 tablas principales y sus relaciones). |

El esquema se versiona con migraciones Flyway en el repositorio HurryUpDuocBack (carpeta `src/main/resources/db/migration`). Las tablas `applications` y `module_requests` corresponden al acceso por postulación y a los complementos solicitados.
