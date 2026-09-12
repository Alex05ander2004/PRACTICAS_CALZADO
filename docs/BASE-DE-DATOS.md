# La base de datos: tres formas de tenerla

No son lo mismo, y la más cómoda no es la que parece. Ordenadas de menos a más
trabajo:

---

## 1 · No montarla: usar la que ya está *(recomendado)*

La base de la entrega ya está creada y cargada, y `proyecto/js/config.js` apunta
a ella. Basta con levantar el servidor y entrar.

- **Hace falta:** nada.
- **Tiempo:** dos minutos.
- **Da:** el sistema tal cual, con sus datos y sus cinco cuentas ya creadas.

Está explicado en **INSTALACION.md**, parte A.

---

## 2 · Reconstruirla desde las migraciones *(la receta)*

Todo desde el **SQL Editor** del navegador, sin instalar nada.

- `proyecto/supabase/schema-completo.sql` — las 33 migraciones concatenadas
- `proyecto/supabase/migrations/` — las mismas, una a una, cada una explicando
  qué problema resolvía
- `proyecto/supabase/seed/` — los datos, en cuatro pasos

- **Hace falta:** una cuenta de Supabase.
- **Tiempo:** unos veinte minutos, casi todos esperando al SQL.
- **Da:** el mismo sistema, partiendo de cero.
- **No da:** los usuarios. `auth` es un esquema aparte que las migraciones no
  tocan, así que las cinco cuentas se crean a mano (**USUARIOS-Y-ROLES.md** lo
  explica; son unos minutos).

**Es lo que hay que leer para entender cómo está construido.** Las migraciones
están numeradas y comentadas: cada una dice qué problema resolvía y por qué se
resolvió así.

Paso a paso en **INSTALACION.md**, parte B.

---

## 3 · Restaurar un volcado *(la foto)*

Un `.sql` con el estado exacto de la base: los datos, los movimientos ya
ejecutados, los casilleros como están **y los usuarios**.

Suena a lo más cómodo, pero **es lo más incómodo de las tres**: un volcado de
`pg_dump` no se puede pegar en el SQL Editor —lleva instrucciones propias de
`psql`, como `COPY ... \.`— así que hay que **instalar PostgreSQL** para
restaurarlo.

**Generarlo**, desde una máquina con la CLI de Supabase:

```bash
supabase db dump --db-url "postgresql://postgres:[CONTRASEÑA]@db.[PROYECTO].supabase.co:5432/postgres" -f volcado.sql
```

La cadena de conexión está en **Settings → Database → Connection string**.

**Restaurarlo** en un proyecto nuevo y vacío:

```bash
psql "postgresql://postgres:[CONTRASEÑA]@db.[NUEVO].supabase.co:5432/postgres" -f volcado.sql
```

- **Hace falta:** PostgreSQL instalado, la CLI de Supabase y la contraseña de la
  base.
- **Solo compensa si:** hace falta el estado exacto con los usuarios incluidos.

> Un volcado que incluya el esquema `auth` lleva los **hashes** de las
> contraseñas. No son las contraseñas en claro, pero es un archivo que no
> conviene dejar circulando de más.

---

## En resumen

| Si quieres… | Usa |
|---|---|
| Probarlo cuanto antes | **1** — ya está montado |
| Entender cómo está hecho | **2** — las migraciones, comentadas |
| Montarlo en tu propio Supabase | **2**, y creas los usuarios |
| Clonar el estado exacto, usuarios incluidos | **3**, si tienes las herramientas |

Para **evaluar** el trabajo, la 2 es la que cuenta: ahí está el diseño y el
porqué de cada decisión. La 1 es para verlo funcionando sin perder tiempo.
