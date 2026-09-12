# Instalación y puesta en marcha

Hay dos formas de tener esto funcionando. **La primera son dos minutos y no
requiere instalar nada**; la segunda es para montarlo sobre una base de datos
propia.

El código está en **https://github.com/Alex05ander2004/PRACTICAS_CALZADO**
(también viene completo en esta carpeta; el repositorio sirve para ver el
historial de cambios, que es donde se explica por qué el sistema es así).

---

# A · Arrancar contra la base que ya existe *(recomendado)*

La base de datos ya está creada y cargada, y la aplicación viene apuntando a
ella. No hace falta cuenta de Supabase ni ejecutar SQL.

**Lo único que hace falta es un servidor de archivos.** Cualquiera sirve; con
Python, que suele venir instalado:

```bash
python -m http.server 5173
```

Desde la carpeta del proyecto (donde está `index.html`). Y abrir:

**http://localhost:5173**

Entrar con cualquiera de las cuentas de [`docs/USUARIOS-Y-ROLES.md`](docs/USUARIOS-Y-ROLES.md).
Para ver el sistema entero conviene empezar por Ana (la jefa), que lo ve todo.

> **No sirve abrir `index.html` con doble clic.** El navegador bloquea las
> peticiones desde `file://` y la pantalla se queda en el login sin dejar
> entrar. Hace falta el servidor, aunque sea este de una línea.

¿Sin Python? Vale cualquiera de estos:

```bash
npx serve -l 5173          # si hay Node
php -S localhost:5173      # si hay PHP
```

O la extensión **Live Server** de VS Code (clic derecho en `index.html` →
*Open with Live Server*).

Con esto ya se puede seguir [`docs/GUIA-DE-PRUEBAS.md`](docs/GUIA-DE-PRUEBAS.md),
que recorre el sistema en ocho casos.

---

# B · Montarlo sobre una base de datos propia

Si se quiere una instancia independiente —para trastear sin tocar la original, o
porque la de la entrega ya no esté—, esto la levanta desde cero. Todo se hace
desde el **SQL Editor** del navegador: no hay que instalar `psql` ni nada.

Unos veinte minutos, casi todos de esperar a que corra el SQL.

## B.1 · Crear el proyecto

1. En [supabase.com](https://supabase.com), crear un proyecto nuevo.
2. Anotar la contraseña de la base: no se puede recuperar después.
3. En **Settings → API**, copiar:
   - **Project URL** — `https://xxxxx.supabase.co`
   - **anon public** — la clave larga que empieza por `eyJ...`

## B.2 · El esquema

En el **SQL Editor**, pegar y ejecutar:

```
supabase/schema-completo.sql
```

Son las 33 migraciones concatenadas: 23 tablas, 10 vistas, 74 funciones,
políticas RLS y triggers. Tarda un minuto largo.

> Si se prefieren de una en una, están en `supabase/migrations/`, numeradas y
> comentadas. **No existe la 25**: era un rediseño descartado, y se dejó el
> hueco en vez de renumerar (renumerar migraciones ya aplicadas es la forma más
> fácil de aplicar dos veces la misma).

## B.3 · El primer usuario, y hacerlo jefe

**Authentication → Users → Add user**, marcando **Auto Confirm User**. Al
crearse, un trigger le hace un perfil automáticamente **con rol OPERARIO** — el
mínimo, siempre.

Después, en el SQL Editor:

```sql
update public.profiles set role = 'JEFE' where email = 'tu@correo.com';
```

Este paso es manual **a propósito**: si el registro público pudiera crear jefes,
el enlace de alta sería la puerta de atrás del almacén.

## B.4 · Los datos

Cuatro archivos, en este orden:

```
supabase/seed/seed.sql                  los 20 artículos del CSV original
supabase/seed/02_seed_ampliacion.sql    hasta 65 modelos, 3 almacenes, 16 racks
supabase/seed/03_seed_infantil.sql      la línea infantil
supabase/seed/04_ajustes_post_seed.sql  ← no saltarse este
```

El cuarto **no es opcional**. Cuatro de las migraciones no crean estructura sino
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

## B.5 · Apuntar la aplicación a la base nueva

```bash
cp js/config.example.js js/config.js
```

Y poner dentro los dos datos de B.1:

```js
const SUPABASE_CONFIG = {
  url: 'https://xxxxx.supabase.co',
  anonKey: 'eyJ...',
};
```

La `url` va **sin** `/rest/v1/` al final: el cliente arma esa ruta por su cuenta,
y dejarla duplica la ruta en cada petición y todo responde 404.

## B.6 · Las demás cuentas

Con una sola cuenta **no se puede probar el workflow**: el sistema impide que
quien crea un movimiento lo apruebe, y eso es deliberado. Para recorrerlo
completo hacen falta tres personas.

Las cinco cuentas de prueba y el SQL que les asigna el rol están en
[`docs/USUARIOS-Y-ROLES.md`](docs/USUARIOS-Y-ROLES.md). Se crean igual que la
primera: **Authentication → Add user**, con *Auto Confirm*.

Y ya se puede levantar el servidor como en la parte A.

---

## Si algo falla

| Síntoma | Qué pasa |
|---|---|
| La pantalla se queda en el login y no entra | Se abrió el `index.html` con doble clic. Hace falta un servidor |
| Todo responde 404 | La `url` de `config.js` lleva `/rest/v1/` al final. Quitarlo |
| `permission denied for table ...` | No hay sesión: sin ella el cliente es `anon`, que no tiene acceso a nada. Volver a entrar |
| `Tu rol (OPERARIO) no autoriza esta operación` | No es un fallo: es el sistema funcionando. Entrar con una cuenta con permiso |
| Los racks aparecen sin casilleros | Faltó el paso B.4 (el cuarto archivo) |
| Los artículos no tienen peso ni medidas | Faltó el paso B.4 |
| Al ejecutar un movimiento dice que el casillero no admite el artículo | Faltó el paso B.4 |

---

## Sobre clonar la base con un volcado

Se puede, pero **es el camino más difícil de los tres**, no el más fácil:
restaurar un volcado necesita `psql` instalado (un `.sql` de `pg_dump` no se
puede pegar en el SQL Editor, porque lleva instrucciones propias de psql). Solo
compensa si hace falta el estado exacto de la base, con los usuarios incluidos.

Los comandos están en `base-de-datos/LEEME.md` de la carpeta de entrega.

---

## Qué hay en cada carpeta

```
index.html                   la aplicación entera, una sola página
css/                         estilos
js/                          cliente: api/ habla con Supabase, el resto es interfaz
supabase/schema-completo.sql las 33 migraciones juntas (B.2)
supabase/migrations/         las mismas, una a una
supabase/seed/               datos de ejemplo (B.4)
supabase/tests/              comprobaciones de integridad, se corren a mano
docs/                        roles y credenciales, guía de pruebas, análisis operativo
README.md                    arquitectura, base de datos, workflow y seguridad
```
