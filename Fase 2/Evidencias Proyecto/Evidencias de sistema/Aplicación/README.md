# Evidencias de sistema · Aplicación

HurryUp es una aplicación web en tres partes: interfaz (HurryFront), API (HurryBack) y facturación (HurryBilling). El acceso por postulación sin cobro se implementó en las variantes HurryUpDuoc.

## Código fuente

| Proyecto | Repositorio | Commit (rama develop) |
|---|---|---|
| HurryBack (API) | github.com/CheVenom/HurryBack | 8ecbb27 |
| HurryBilling (planes y pagos) | github.com/CheVenom/HurryBilling | 7dff813 |
| HurryFront (interfaz) | github.com/CheVenom/HurryFront | 59d23d2 |
| HurryUpDuocBack (acceso por postulación) | github.com/CheVenom/HurryUpDuocBack | d25db9f |
| HurryUpDuocFront (acceso por postulación) | github.com/CheVenom/HurryUpDuocFront | e7853bd |

Los repositorios son privados.

## Capturas

| Archivo | Qué muestra |
|---|---|
| 01_Pagina_principal.jpg | Página principal con los botones «Únete a nosotros» y «Postular». |
| 02_Planes_acceso_por_postulacion.jpg | Planes Solitario y Duo con el acceso «Sin costo» y el botón «Postular con este plan». |
| 03_Registro_previo_a_postular.jpg | Registro de la cuenta, paso previo a la postulación con plan y motivo. |
| 04_Marketplace_listado_de_negocios.jpg | Listado público de negocios con rubro, ubicación, sucursales y valoración. |

## Cómo se ejecuta (variante con acceso por postulación)

- Base de datos PostgreSQL local (esquema en la carpeta «Base de datos»).
- Back: `./gradlew bootRun` en HurryUpDuocBack (puerto 8280, ruta base `/api`).
- Front: `npx next dev -p 3100` en HurryUpDuocFront (http://localhost:3100).
- Archivo `.env` compartido en la carpeta superior de los proyectos.

## Flujo comprobado de punta a punta (22/10/2026)

Registro → postulación con plan y motivo → aviso por correo al Super Admin → aceptación desde el modal del panel → correo de aceptación → onboarding y creación del negocio → solicitud de un complemento → activación sin costo por el Super Admin → correos de aviso. El detalle está en la Ficha 06 (pruebas de calidad).
