# Instalación y puesta en marcha

Cómo dejar el sistema funcionando en un equipo nuevo, desde cero. Son cuatro
pasos y unos veinte minutos, casi todos de esperar a que corra el SQL.

Hace falta: una cuenta gratuita de **Supabase** y **Python** (o cualquier cosa
que sirva archivos por HTTP). No hay que instalar dependencias ni compilar nada.

El código está en **https://github.com/Alex05ander2004/PRACTICAS_CALZADO**
(también viene completo en esta carpeta; el repositorio sirve para ver el
historial de cambios, que es donde se explica por qué el sistema es así).

---

## Paso 1 · Crear el proyecto de Supabase

1. Entra en [supabase.com](https://supabase.com) y crea un proyecto nuevo.
2. Anota la contraseña de la base que te pida: no se puede recuperar después.
3. Cuando termine de aprovisionarse, ve a **Settings → API** y copia:
   - **Project URL** — algo como `https://xxxxx.supabase.co`
   - **anon public** — una clave larga que empieza por `eyJ...`

---

## Paso 2 · Crear la base de datos

En el **SQL Editor** del proyecto, en este orden:

### 2.1 · El esquema

Pega y ejecuta el contenido de:

```
supabase/schema-completo.sql
```

Son las 33 migraciones concatenadas: 23 tablas, 10 vistas, 74 funciones,
políticas RLS y triggers. Tarda un minuto largo.

> Si prefieres verlas una a una, están en `supabase/migrations/`, numeradas.
> Se ejecutan en orden. **No existe la 25**: era un rediseño descartado, y se
> dejó el hueco en vez de renumerar (renumerar migraciones ya aplicadas es la
> forma más fácil de aplicar dos veces la misma).

### 2.2 · Tu usuario, y hacerlo jefe

Ve a **Authentication → Users → Add user**, marca **Auto Confirm User** y crea
tu cuenta. Al crearse, un trigger le hace un perfil automáticamente **con rol
OPERARIO** — el mínimo, siempre.

Vuelve al SQL Editor y ascéndete:

```sql
update public.profiles set role = 'JEFE' where email = 'tu@correo.com';
```

Esto se hace a mano **a propósito**: si el registro público pudiera crear jefes,
el enlace de alta sería la puerta de atrás del almacén.

### 2.3 · Los datos

Tres archivos, en orden, desde el SQL Editor:

```
supabase/seed/seed.sql                 los 20 artículos del CSV original
supabase/seed/02_seed_ampliacion.sql   hasta 65 modelos, 3 almacenes, 16 racks
supabase/seed/03_seed_infantil.sql     la línea infantil
```

### 2.4 · Los ajustes de después

```
supabase/seed/04_ajustes_post_seed.sql
```

**Este paso no es opcional.** Cuatro de las migraciones no crean estructura sino
que transforman datos, y al correrlas sobre una base vacía no encuentran nada
que transformar. Este archivo las repite ahora que los datos ya están: parte los
racks en casilleros a medida, pone las medidas de caja a cada artículo y corrige
los movimientos que apuntan a un casillero imposible.

Al terminar imprime un resumen. Debería decir algo así:

```
 Articulos:        80
 Pares en stock:   2376
 Casilleros:       3208
 Pares en estante: 2376
 Incidencias:      0   <- deberia ser 0
```

Si "Incidencias" no es 0, la sección **Revisión de ubicaciones** del mapa dice
cuáles son y permite corregirlas.

---

## Paso 3 · Configurar el frontend

Copia la plantilla y pon tus dos datos del paso 1:

```bash
cp js/config.example.js js/config.js
```

```js
const SUPABASE_CONFIG = {
  url: 'https://xxxxx.supabase.co',
  anonKey: 'eyJ...',
};
```

La `url` va **sin** `/rest/v1/` al final: el cliente arma esa ruta por su cuenta,
y dejarla duplica la ruta en cada petición y todo responde 404.

> `js/config.js` no está en el repositorio y `js/config.example.js` sí. La
> `anon key` **no es un secreto** —está pensada para viajar en el navegador, y
> lo que protege los datos es RLS— pero cada quien apunta a su propio proyecto.

---

## Paso 4 · Levantar la aplicación

Desde la carpeta del proyecto:

```bash
python -m http.server 5173
```

Y abre **http://localhost:5173**.

Sirve cualquier servidor estático (`npx serve`, la extensión Live Server de
VS Code, lo que tengas). Lo que **no** funciona es abrir `index.html` con doble
clic: el navegador bloquea las peticiones desde `file://` y la pantalla se queda
en el login sin poder entrar.

Entra con el usuario del paso 2.2.

---

## Paso 5 · Las demás cuentas (para ver el sistema entero)

Con una sola cuenta **no se puede probar el workflow**: el sistema impide que
quien crea un movimiento lo apruebe, y eso es deliberado (segregación de
funciones). Para recorrerlo completo hacen falta tres personas.

Las cuentas de prueba, sus contraseñas y el SQL que les asigna el rol están en
[`docs/USUARIOS-Y-ROLES.md`](docs/USUARIOS-Y-ROLES.md). Se crean igual que la
tuya: **Authentication → Add user**, con *Auto Confirm*.

Después, [`docs/GUIA-DE-PRUEBAS.md`](docs/GUIA-DE-PRUEBAS.md) lleva de la mano
por ocho recorridos que cubren todo el sistema.

---

## Si algo falla

| Síntoma | Qué pasa |
|---|---|
| La pantalla se queda en el login y no entra | Abriste el `index.html` con doble clic. Hace falta un servidor (paso 4) |
| Todo responde 404 | La `url` de `config.js` lleva `/rest/v1/` al final. Quítalo |
| `permission denied for table ...` | No hay sesión: el cliente pasa a ser `anon`, que no tiene acceso a nada. Vuelve a entrar |
| `Tu rol (OPERARIO) no autoriza esta operación` | No es un fallo: es el sistema funcionando. Entra con una cuenta con permiso |
| Los racks aparecen sin casilleros | Faltó el paso 2.4 |
| Los artículos no tienen peso ni medidas | Faltó el paso 2.4 |
| Al ejecutar un movimiento dice que el casillero no admite el artículo | Faltó el paso 2.4 |

---

## Qué hay en cada carpeta

```
index.html                   la aplicación entera, una sola página
css/                         estilos
js/                          cliente: api/ habla con Supabase, el resto es interfaz
supabase/schema-completo.sql las 33 migraciones juntas (paso 2.1)
supabase/migrations/         las mismas, una a una
supabase/seed/               datos de ejemplo (pasos 2.3 y 2.4)
supabase/tests/              comprobaciones de integridad, se corren a mano
docs/                        roles y credenciales, guía de pruebas, análisis operativo
README.md                    arquitectura, base de datos, workflow y seguridad
```
