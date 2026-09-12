# WMS Calzado — entrega

Sistema de gestión de inventario para un almacén de calzado.
**Supabase** (PostgreSQL) + **HTML, CSS y JavaScript sin frameworks**.

---

## Verlo funcionando: dos minutos

La base de datos ya está creada y la aplicación viene apuntando a ella. Desde
la carpeta `proyecto/`:

```bash
python -m http.server 5173
```

Y abrir **http://localhost:5173**. Entrar con cualquiera de las cuentas de
**USUARIOS-Y-ROLES.md** — empezando por Ana (la jefa), que lo ve todo.

> **No sirve abrir `index.html` con doble clic**: el navegador bloquea las
> peticiones desde `file://` y la pantalla se queda en el login. Hace falta el
> servidor, aunque sea esa línea. Si no hay Python, vale `npx serve -l 5173`,
> `php -S localhost:5173` o la extensión Live Server de VS Code.

No hace falta cuenta de Supabase ni ejecutar SQL para probarlo. Montarlo sobre
una base propia también se puede, y está en **INSTALACION.md**, parte B.

---

## Enlaces

- **Código y historial de cambios:**
  https://github.com/Alex05ander2004/PRACTICAS_CALZADO
- **Base de datos:** Supabase (el acceso al proyecto se entrega aparte)

El repositorio sirve para ver **cómo se llegó hasta aquí**: cada commit explica
qué problema resolvía.

---

## Qué leer, y en qué orden

| | Documento | Para qué |
|---|---|---|
| 1 | **INSTALACION.md** | Arrancarlo. Parte A: dos minutos. Parte B: sobre una base propia |
| 2 | **README.md** | Arquitectura, las 23 tablas y sus relaciones, el workflow, la seguridad |
| 3 | **GUIA-DE-PRUEBAS.md** | Ocho recorridos para probarlo todo sin explorar a ciegas |
| 4 | **USUARIOS-Y-ROLES.md** | Los cuatro roles y las cuentas de prueba |
| 5 | **ANALISIS-OPERATIVO.md** | Qué puede salir mal en un almacén real y cómo lo ataja el sistema |

Los cinco están también dentro de `proyecto/docs/` — aquí sueltos para poder
leerlos sin descomprimir nada.

---

## Una cosa que conviene saber antes de probar

**Con una sola cuenta no se puede recorrer el sistema entero, y es a propósito.**

El sistema impide que quien crea un movimiento lo apruebe — segregación de
funciones, el control interno más básico contra el fraude de inventario. No es
una comprobación del JavaScript: es una restricción de la propia base de datos.

Por eso hay cinco cuentas de prueba y el caso principal de la guía se recorre
entre tres personas: **Luis crea, Ana aprueba, Rosa ejecuta.**

---

## Qué hay en esta carpeta

```
0 - EMPIEZA-AQUI.md          este archivo
1 a 5                        la documentación, en orden de lectura
base-de-datos/               las tres formas de tener la base, comparadas
proyecto/                    el código completo
wms-calzado-codigo.zip       el mismo código, comprimido
```

Y dentro de `proyecto/`:

```
index.html  css/  js/         la aplicación
supabase/schema-completo.sql  toda la base de datos en un archivo
supabase/migrations/          las 33 migraciones, una a una y comentadas
supabase/seed/                los datos de ejemplo
supabase/tests/               comprobaciones de integridad
docs/                         la documentación
```

Unos números para situarse: 23 tablas, 10 vistas, 74 funciones, 33 migraciones,
80 artículos, 65 modelos, 3 almacenes, 16 racks y unos 3 200 casilleros.
