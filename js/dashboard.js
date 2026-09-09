// Orquesta la pantalla: login -> carga de datos reales -> render.
// Fase 4: solo estructura + KPIs + tabla de lectura. Búsqueda/filtros llegan en
// la Fase 5; los botones de Acciones quedan deshabilitados hasta la Fase 6.

const formatoMoneda = new Intl.NumberFormat('es-PE', { style: 'currency', currency: 'PEN' });

// Misma lógica que la vista v_stock_actual (supabase/migrations/02_...sql) —
// se replica en el cliente porque CatalogoAPI.listarArticulos() no pasa por
// esa vista (necesita más columnas de las que expone). Debe leerse igual que
// el CASE de la vista para que el dashboard y la base nunca se contradigan.
function calcularEstadoStock(inv) {
  if (!inv) return 'SIN_DATO';
  if (inv.quantity === 0) return 'SIN_STOCK';
  if (inv.quantity <= inv.min_stock) return 'BAJO_MINIMO';
  if (inv.max_stock != null && inv.quantity > inv.max_stock) return 'SOBRE_MAXIMO';
  return 'OK';
}

const ETIQUETA_ESTADO = {
  OK: { texto: 'OK', clase: 'ok' },
  BAJO_MINIMO: { texto: 'Bajo mínimo', clase: 'warn' },
  SIN_STOCK: { texto: 'Sin stock', clase: 'bad' },
  SOBRE_MAXIMO: { texto: 'Sobre máximo', clase: 'ok' },
  SIN_DATO: { texto: 'Sin registro', clase: 'warn' },
};

// Un artículo puede tener stock en más de un almacén; para la vista resumen
// se suma. inventory[0] se usa para min/max porque, en este proyecto, cada
// artículo vive en un solo almacén (ver DISENO.md) — sumar cantidades es
// correcto para el total, pero min/max no tendría sentido promediados.
function stockDelArticulo(articulo) {
  const filas = articulo.inventory ?? [];
  const cantidad = filas.reduce((acc, f) => acc + f.quantity, 0);
  return { cantidad, filaPrincipal: filas[0] ?? null };
}

function mostrarLogin() {
  document.getElementById('pantallaLogin').hidden = false;
  document.getElementById('pantallaDashboard').hidden = true;
}

function mostrarDashboard() {
  document.getElementById('pantallaLogin').hidden = true;
  document.getElementById('pantallaDashboard').hidden = false;
}

function renderTopbar(perfil) {
  document.getElementById('usuarioNombre').textContent = perfil.full_name;
  document.getElementById('usuarioRol').textContent = perfil.role;
}

function renderKpis(articulos, movimientos) {
  const cont = document.getElementById('kpis');

  const totalArticulos = articulos.length;

  let stockTotal = 0;
  let bajoMinimo = 0;
  let valorTotal = 0;

  for (const art of articulos) {
    const { cantidad, filaPrincipal } = stockDelArticulo(art);
    stockTotal += cantidad;
    if (filaPrincipal && calcularEstadoStock(filaPrincipal) === 'BAJO_MINIMO') bajoMinimo += 1;
    if (art.price != null) valorTotal += cantidad * art.price;
  }

  const haceUnaSemana = Date.now() - 7 * 24 * 60 * 60 * 1000;
  const movimientosRecientes = movimientos.filter(
    (m) => new Date(m.created_at).getTime() >= haceUnaSemana
  ).length;

  cont.innerHTML = `
    <div class="kpi">
      <span class="valor mono">${totalArticulos}</span>
      <span class="etiqueta">Total de artículos</span>
    </div>
    <div class="kpi">
      <span class="valor mono">${stockTotal}</span>
      <span class="etiqueta">Stock total (pares)</span>
    </div>
    <div class="kpi ${bajoMinimo > 0 ? 'alerta' : ''}">
      <span class="valor mono">${bajoMinimo}</span>
      <span class="etiqueta">Bajo stock mínimo</span>
    </div>
    <div class="kpi">
      <span class="valor mono">${formatoMoneda.format(valorTotal)}</span>
      <span class="etiqueta">Valor total del inventario</span>
    </div>
    <div class="kpi">
      <span class="valor mono">${movimientosRecientes}</span>
      <span class="etiqueta">Movimientos recientes</span>
      <span class="detalle">en los últimos 7 días</span>
    </div>
  `;
}

function filaArticulo(art) {
  const { cantidad, filaPrincipal } = stockDelArticulo(art);
  const estado = calcularEstadoStock(filaPrincipal);
  const { texto, clase } = ETIQUETA_ESTADO[estado];

  const nombre = art.product?.name ?? '—';
  const talla = art.size_label ? ` · Talla ${art.size_label}` : '';
  const categoria = art.product?.category?.name ?? '—';
  const proveedor = art.product?.supplier?.name ?? '—';
  const costo = art.cost != null ? formatoMoneda.format(art.cost) : '—';
  const precio = art.price != null ? formatoMoneda.format(art.price) : '—';

  const esInfantil = art.product?.audience === 'NINO';
  const insigniaPublico = esInfantil ? '<span class="pill nino">Niño</span>' : '';

  const tr = document.createElement('tr');
  tr.dataset.estado = estado;
  tr.innerHTML = `
    <td class="mono">${art.sku}</td>
    <td>${nombre}${talla} ${insigniaPublico}</td>
    <td>${categoria}</td>
    <td class="celda-num">${cantidad}</td>
    <td class="celda-num">${costo}</td>
    <td class="celda-num">${precio}</td>
    <td>${proveedor}</td>
    <td><span class="pill ${clase}">${texto}</span></td>
    <td class="acciones">
      <button class="btn-accion" disabled title="Disponible en la Fase 6">Editar</button>
      <button class="btn-accion" disabled title="Disponible en la Fase 6">Eliminar</button>
    </td>
  `;
  return tr;
}

function renderTabla(articulos, hayFiltrosActivos) {
  const cuerpo = document.getElementById('tablaArticulosBody');
  cuerpo.innerHTML = '';

  if (articulos.length === 0) {
    cuerpo.innerHTML = hayFiltrosActivos
      ? `<tr><td colspan="9">
          <div class="estado-vacio"><p>Ningún artículo coincide</p><p>Prueba con otra búsqueda o quita algún filtro.</p></div>
        </td></tr>`
      : `<tr><td colspan="9">
          <div class="estado-vacio"><p>Sin artículos todavía</p><p>Crea el primero desde la Fase 6.</p></div>
        </td></tr>`;
    return;
  }

  const fragmento = document.createDocumentFragment();
  for (const art of articulos) fragmento.appendChild(filaArticulo(art));
  cuerpo.appendChild(fragmento);
}

// --- Búsqueda y filtros (Fase 5) -------------------------------------------
// Todo se filtra en el navegador: con ~80 artículos no hace falta ir a la base
// por cada tecleo, y así el buscador responde al instante.
let todosLosArticulos = [];

function normalizar(texto) {
  return (texto ?? '')
    .toString()
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, ''); // quita tildes para que "botin" encuentre el acentuado
}

function poblarSelectDesdeArticulos(id, obtenerValor) {
  const select = document.getElementById(id);
  const valorPrevio = select.value;
  const valores = [...new Set(todosLosArticulos.map(obtenerValor).filter(Boolean))].sort((a, b) =>
    a.localeCompare(b, 'es')
  );

  // La primera opción ("todas"/"todos") ya está en el HTML; el resto se genera.
  select.length = 1;
  for (const v of valores) {
    const opt = document.createElement('option');
    opt.value = v;
    opt.textContent = v;
    select.appendChild(opt);
  }
  if (valores.includes(valorPrevio)) select.value = valorPrevio;
  sincronizarSelectMejorado(id);
}

function aplicarFiltros() {
  const texto = normalizar(document.getElementById('filtroTexto').value.trim());
  const categoria = document.getElementById('filtroCategoria').value;
  const proveedor = document.getElementById('filtroProveedor').value;
  const publico = document.getElementById('filtroPublico').value;
  const estadoBuscado = document.getElementById('filtroStock').value;

  const hayFiltrosActivos = Boolean(texto || categoria || proveedor || publico || estadoBuscado);

  const filtrados = todosLosArticulos.filter((art) => {
    if (texto) {
      const coincideTexto =
        normalizar(art.sku).includes(texto) || normalizar(art.product?.name).includes(texto);
      if (!coincideTexto) return false;
    }
    if (categoria && art.product?.category?.name !== categoria) return false;
    if (proveedor && art.product?.supplier?.name !== proveedor) return false;
    if (publico && art.product?.audience !== publico) return false;
    if (estadoBuscado) {
      const { filaPrincipal } = stockDelArticulo(art);
      if (calcularEstadoStock(filaPrincipal) !== estadoBuscado) return false;
    }
    return true;
  });

  document.getElementById('contadorResultados').textContent =
    `${filtrados.length} de ${todosLosArticulos.length} artículos`;
  renderTabla(filtrados, hayFiltrosActivos);
}

function inicializarFiltros(articulos) {
  todosLosArticulos = articulos;

  poblarSelectDesdeArticulos('filtroCategoria', (a) => a.product?.category?.name);
  poblarSelectDesdeArticulos('filtroProveedor', (a) => a.product?.supplier?.name);

  aplicarFiltros();
}

let debounceTexto;
document.getElementById('filtroTexto').addEventListener('input', () => {
  clearTimeout(debounceTexto);
  debounceTexto = setTimeout(aplicarFiltros, 150);
});
for (const id of ['filtroCategoria', 'filtroProveedor', 'filtroPublico', 'filtroStock']) {
  document.getElementById(id).addEventListener('change', aplicarFiltros);
}
document.getElementById('btnLimpiarFiltros').addEventListener('click', () => {
  document.getElementById('filtroTexto').value = '';
  for (const id of ['filtroCategoria', 'filtroProveedor', 'filtroPublico', 'filtroStock']) {
    document.getElementById(id).value = '';
    sincronizarSelectMejorado(id);
  }
  aplicarFiltros();
});

// Los selects nativos siguen siendo la fuente de verdad de los filtros; esto
// solo les pone encima un dropdown con el mismo estilo que el resto del
// dashboard (ver js/custom-select.js).
for (const id of ['filtroCategoria', 'filtroProveedor', 'filtroPublico', 'filtroStock']) {
  mejorarSelect(id);
}

async function cargarDashboard() {
  const perfil = await AuthAPI.obtenerPerfilActual();
  if (!perfil) {
    // Sesión válida pero sin fila en profiles: no debería pasar con el
    // trigger de auto-provisión, pero si pasa, mejor decirlo que romper en
    // silencio contra RLS.
    await AuthAPI.cerrarSesion();
    mostrarLogin();
    document.getElementById('loginError').hidden = false;
    document.getElementById('loginError').textContent =
      'Tu cuenta no tiene un perfil activo en el sistema. Contacta al jefe de almacén.';
    return;
  }

  mostrarDashboard();
  renderTopbar(perfil);

  const [articulos, movimientos] = await Promise.all([
    CatalogoAPI.listarArticulos(),
    MovimientosAPI.listar(),
  ]);

  renderKpis(articulos, movimientos);
  inicializarFiltros(articulos);
}

document.getElementById('formLogin').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  const email = document.getElementById('loginEmail').value.trim();
  const password = document.getElementById('loginPassword').value;
  const errorEl = document.getElementById('loginError');
  const boton = evento.target.querySelector('button[type="submit"]');

  errorEl.hidden = true;
  boton.disabled = true;
  boton.textContent = 'Ingresando…';

  try {
    await AuthAPI.iniciarSesion(email, password);
    await cargarDashboard();
  } catch (err) {
    errorEl.textContent = 'No se pudo iniciar sesión: correo o contraseña incorrectos.';
    errorEl.hidden = false;
  } finally {
    boton.disabled = false;
    boton.textContent = 'Iniciar sesión';
  }
});

document.getElementById('btnSalir').addEventListener('click', async () => {
  await AuthAPI.cerrarSesion();
  mostrarLogin();
});

(async function init() {
  const sesion = await AuthAPI.obtenerSesion();
  if (sesion) {
    await cargarDashboard();
  } else {
    mostrarLogin();
  }
})();
