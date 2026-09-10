// Plano del almacén: vista aérea editable + ruta más corta con A*.
//
// El almacén es una grilla de celdas (1 celda ≈ 1 m). Cada rack es un
// rectángulo que ocupa celdas y las BLOQUEA. Los pasillos no se declaran en
// ningún lado: son simplemente las celdas que ningún rack ocupa. Por eso al
// arrastrar un rack en el editor las rutas cambian solas — no hay una
// topología paralela que mantener sincronizada.

let layoutAlmacenes = [];
let layoutRacks = [];
let rutaActual = null;      // { almacenCode, celdas: [[x,y], ...] }
let modoEdicion = false;
let racksModificados = new Map(); // rackId -> { gridX, gridY, gridAncho, gridAlto }
let rackSeleccionado = null;      // id del rack cuyo panel de propiedades está abierto

function inicializarLayout(layout) {
  layoutAlmacenes = layout.almacenes;
  layoutRacks = layout.racks;
}

function almacenPorCodigo(codigo) {
  return layoutAlmacenes.find((a) => a.code === codigo);
}

function racksDe(almacenId) {
  return layoutRacks.filter((r) => r.warehouse_id === almacenId);
}

// La geometría "en vivo" de un rack: si el editor lo movió y todavía no se
// guardó, manda lo que se ve en pantalla, no lo que dice la base.
function geometriaDe(rack) {
  const pendiente = racksModificados.get(rack.id);
  return pendiente ?? {
    gridX: rack.grid_x,
    gridY: rack.grid_y,
    gridAncho: rack.grid_ancho,
    gridAlto: rack.grid_alto,
  };
}

// =============================================================================
//  A* SOBRE LA GRILLA
// =============================================================================

// Matriz de celdas bloqueadas por los racks del almacén.
function construirGrilla(almacen, racks) {
  const grilla = Array.from({ length: almacen.grid_alto }, () =>
    new Array(almacen.grid_ancho).fill(false)
  );
  for (const rack of racks) {
    const g = geometriaDe(rack);
    for (let y = g.gridY; y < g.gridY + g.gridAlto; y++) {
      for (let x = g.gridX; x < g.gridX + g.gridAncho; x++) {
        if (grilla[y] && x < almacen.grid_ancho) grilla[y][x] = true;
      }
    }
  }
  return grilla;
}

// Un rack no se puede pisar, así que "llegar al rack" significa llegar a una
// celda libre pegada a su perímetro: el lugar donde se para la persona para
// tomar la mercadería.
function celdasDeAcceso(grilla, geometria) {
  const metas = [];
  const alto = grilla.length;
  const ancho = grilla[0].length;
  for (let y = geometria.gridY - 1; y <= geometria.gridY + geometria.gridAlto; y++) {
    for (let x = geometria.gridX - 1; x <= geometria.gridX + geometria.gridAncho; x++) {
      const dentroDelRack =
        x >= geometria.gridX && x < geometria.gridX + geometria.gridAncho &&
        y >= geometria.gridY && y < geometria.gridY + geometria.gridAlto;
      if (dentroDelRack) continue;
      if (x < 0 || y < 0 || x >= ancho || y >= alto) continue;
      if (!grilla[y][x]) metas.push([x, y]);
    }
  }
  return metas;
}

const clave = (x, y) => `${x},${y}`;

// A* con 8 direcciones. La cola de prioridad es una búsqueda lineal del
// mínimo: con una grilla de 40x30 (1200 celdas) un heap sería
// sobre-ingeniería y esto se lee mucho mejor.
function calcularRutaAEstrella(grilla, inicio, metas) {
  const alto = grilla.length;
  const ancho = grilla[0].length;
  const metasSet = new Set(metas.map(([x, y]) => clave(x, y)));
  if (metasSet.size === 0) return null;
  if (grilla[inicio[1]]?.[inicio[0]]) return null; // el origen está bloqueado

  // Distancia euclidiana a la meta más cercana: nunca sobreestima el costo
  // real (con diagonales a √2), así que A* sigue garantizando el óptimo.
  const heuristica = (x, y) =>
    Math.min(...metas.map(([mx, my]) => Math.hypot(mx - x, my - y)));

  const g = new Map([[clave(...inicio), 0]]);
  const f = new Map([[clave(...inicio), heuristica(...inicio)]]);
  const anterior = new Map();
  const abiertos = new Set([clave(...inicio)]);
  const cerrados = new Set();

  const DIRECCIONES = [
    [0, -1], [1, 0], [0, 1], [-1, 0],
    [1, -1], [1, 1], [-1, 1], [-1, -1],
  ];

  while (abiertos.size > 0) {
    let actual = null;
    let mejorF = Infinity;
    for (const k of abiertos) {
      const valor = f.get(k) ?? Infinity;
      if (valor < mejorF) { mejorF = valor; actual = k; }
    }

    if (metasSet.has(actual)) {
      const camino = [actual];
      let cursor = actual;
      while (anterior.has(cursor)) {
        cursor = anterior.get(cursor);
        camino.unshift(cursor);
      }
      return {
        celdas: camino.map((k) => k.split(',').map(Number)),
        distancia: g.get(actual),
      };
    }

    abiertos.delete(actual);
    cerrados.add(actual);
    const [ax, ay] = actual.split(',').map(Number);

    for (const [dx, dy] of DIRECCIONES) {
      const nx = ax + dx;
      const ny = ay + dy;
      if (nx < 0 || ny < 0 || nx >= ancho || ny >= alto) continue;
      if (grilla[ny][nx]) continue;

      // En diagonal no se puede "cortar la esquina" entre dos obstáculos:
      // nadie pasa en diagonal entre dos racks que se tocan.
      if (dx !== 0 && dy !== 0 && (grilla[ay][nx] || grilla[ny][ax])) continue;

      const vecino = clave(nx, ny);
      if (cerrados.has(vecino)) continue;

      const costo = (g.get(actual) ?? Infinity) + (dx !== 0 && dy !== 0 ? Math.SQRT2 : 1);
      if (costo < (g.get(vecino) ?? Infinity)) {
        anterior.set(vecino, actual);
        g.set(vecino, costo);
        f.set(vecino, costo + heuristica(nx, ny));
        abiertos.add(vecino);
      }
    }
  }

  return null; // no hay camino: el rack quedó encerrado
}

// =============================================================================
//  DIBUJO DEL PLANO
// =============================================================================

function ocupacionDelRack(mapaFilas, almacenCode, rackCode) {
  const posiciones = mapaFilas.filter((f) => f.almacen_code === almacenCode && f.rack === rackCode);
  const libres = posiciones.filter((f) => f.estado_ocupacion === null).length;
  const capacidad = posiciones.reduce((suma, f) => suma + (f.capacity_units ?? 0), 0);
  const ocupado = posiciones.reduce((suma, f) => suma + (f.unidades ?? 0), 0);
  return { total: posiciones.length, libres, capacidad, ocupado };
}

// Cómo está repartido HOY un rack en pisos y casilleros. Los niveles salen de
// la columna del rack (es una propiedad del mueble); las posiciones por nivel
// se cuentan, porque un rack heredado puede tener unos niveles mapeados y
// otros todavía no.
function configuracionDeRack(rack, almacenCode) {
  const posiciones = todoElMapa.filter((f) => f.almacen_code === almacenCode && f.rack === rack.code);
  const porNivel = new Map();
  for (const f of posiciones) {
    const nivel = f.level ?? 2;
    porNivel.set(nivel, (porNivel.get(nivel) ?? 0) + 1);
  }
  return {
    niveles: rack.niveles ?? Math.max(1, ...porNivel.keys(), 1),
    slots: porNivel.size ? Math.max(...porNivel.values()) : 7,
  };
}

const formatearNumero = (n) => Number(n ?? 0).toLocaleString('es-PE');

function renderUnPlano(almacen, mapaFilas) {
  const bloque = document.createElement('div');
  bloque.className = 'mapa-bloque-almacen';
  bloque.innerHTML = `<p class="mapa-plano-titulo">${almacen.name} — ${almacen.grid_ancho} × ${almacen.grid_alto} m</p>`;

  const plano = document.createElement('div');
  plano.className = 'plano-piso' + (modoEdicion ? ' editando' : '');
  plano.style.aspectRatio = `${almacen.grid_ancho} / ${almacen.grid_alto}`;
  plano.dataset.almacenId = almacen.id;
  // Las celdas de la grilla se dibujan con el fondo, no con 1200 divs.
  plano.style.backgroundSize = `${100 / almacen.grid_ancho}% ${100 / almacen.grid_alto}%`;

  const pct = (v, total) => `${(v / total) * 100}%`;

  // Ruta (debajo de los racks, para que no los tape)
  if (rutaActual?.almacenCode === almacen.code && rutaActual.celdas.length > 1) {
    const puntos = rutaActual.celdas
      .map(([x, y]) => `${((x + 0.5) / almacen.grid_ancho) * 100},${((y + 0.5) / almacen.grid_alto) * 100}`)
      .join(' ');
    plano.innerHTML += `
      <svg class="plano-ruta" viewBox="0 0 100 100" preserveAspectRatio="none">
        <polyline points="${puntos}" />
      </svg>`;
  }

  // Racks
  for (const rack of racksDe(almacen.id)) {
    const g = geometriaDe(rack);
    const { total, libres, capacidad, ocupado } = ocupacionDelRack(mapaFilas, almacen.code, rack.code);

    const el = document.createElement('div');
    el.className = 'plano-rack' + (libres === 0 && total > 0 ? ' lleno' : '');
    if (racksModificados.has(rack.id)) el.classList.add('modificado');
    if (rackSeleccionado === rack.id) el.classList.add('seleccionado');
    el.dataset.rackId = rack.id;
    el.style.left = pct(g.gridX, almacen.grid_ancho);
    el.style.top = pct(g.gridY, almacen.grid_alto);
    el.style.width = pct(g.gridAncho, almacen.grid_ancho);
    el.style.height = pct(g.gridAlto, almacen.grid_alto);
    el.title =
      `${rack.code} — ${g.gridAncho} × ${g.gridAlto} m, ${rack.niveles ?? 1} niveles\n` +
      `${libres} de ${total} posiciones libres\n` +
      `${formatearNumero(ocupado)} de ${formatearNumero(capacidad)} cajas` +
      (modoEdicion ? '\n(arrastra para mover)' : '');
    el.innerHTML = `<span class="plano-rack-etiqueta">${rack.code}</span>`;
    plano.appendChild(el);
  }

  // Entrada
  const entrada = document.createElement('div');
  entrada.className = 'plano-entrada';
  entrada.style.left = pct(almacen.entrada_x, almacen.grid_ancho);
  entrada.style.top = pct(almacen.entrada_y, almacen.grid_alto);
  entrada.title = 'Entrada del almacén';
  entrada.textContent = 'Entrada';
  plano.appendChild(entrada);

  bloque.appendChild(plano);
  if (modoEdicion) habilitarArrastre(plano, almacen);
  return bloque;
}

function renderPlano(almacenFiltro, mapaFilas) {
  const cont = document.getElementById('mapaPlano');
  cont.innerHTML = '';

  const almacenes = almacenFiltro
    ? layoutAlmacenes.filter((a) => a.code === almacenFiltro)
    : layoutAlmacenes;

  if (almacenes.length === 0) {
    cont.innerHTML = '<p class="skeleton">Sin plano cargado.</p>';
    return;
  }
  for (const almacen of almacenes) cont.appendChild(renderUnPlano(almacen, mapaFilas));
}

// =============================================================================
//  EDITOR: ARRASTRAR RACKS SOBRE LA GRILLA
// =============================================================================

function habilitarArrastre(plano, almacen) {
  let arrastrando = null;

  plano.addEventListener('pointerdown', (e) => {
    const rackEl = e.target.closest('.plano-rack');
    if (!rackEl) return;
    e.preventDefault();
    rackEl.setPointerCapture(e.pointerId);

    const rack = layoutRacks.find((r) => r.id === rackEl.dataset.rackId);
    const g = geometriaDe(rack);
    const caja = plano.getBoundingClientRect();

    arrastrando = {
      rackEl,
      rack,
      geometria: g,
      // Se guarda el desfase dentro del rack para que no "salte" al agarrarlo.
      offsetX: (e.clientX - caja.left) / (caja.width / almacen.grid_ancho) - g.gridX,
      offsetY: (e.clientY - caja.top) / (caja.height / almacen.grid_alto) - g.gridY,
      caja,
    };
    rackEl.classList.add('arrastrando');
  });

  plano.addEventListener('pointermove', (e) => {
    if (!arrastrando) return;
    const { caja, geometria, offsetX, offsetY, rackEl } = arrastrando;
    const celdaAncho = caja.width / almacen.grid_ancho;
    const celdaAlto = caja.height / almacen.grid_alto;

    // Snap a la celda + tope en los bordes del plano.
    let x = Math.round((e.clientX - caja.left) / celdaAncho - offsetX);
    let y = Math.round((e.clientY - caja.top) / celdaAlto - offsetY);
    x = Math.max(0, Math.min(x, almacen.grid_ancho - geometria.gridAncho));
    y = Math.max(0, Math.min(y, almacen.grid_alto - geometria.gridAlto));

    arrastrando.nuevaX = x;
    arrastrando.nuevaY = y;
    rackEl.style.left = `${(x / almacen.grid_ancho) * 100}%`;
    rackEl.style.top = `${(y / almacen.grid_alto) * 100}%`;
  });

  const soltar = () => {
    if (!arrastrando) return;
    const { rack, geometria, nuevaX, nuevaY, rackEl } = arrastrando;
    rackEl.classList.remove('arrastrando');

    // Si no se movió, el gesto fue un clic: se interpreta como seleccionar.
    if (nuevaX === undefined || (nuevaX === geometria.gridX && nuevaY === geometria.gridY)) {
      arrastrando = null;
      seleccionarRack(rack.id);
      return;
    }

    if (nuevaX !== undefined && (nuevaX !== geometria.gridX || nuevaY !== geometria.gridY)) {
      racksModificados.set(rack.id, { ...geometria, gridX: nuevaX, gridY: nuevaY });
      rackEl.classList.add('modificado');
      actualizarBarraEdicion();
      // La ruta dibujada ya no corresponde al layout que se está viendo.
      if (rutaActual) {
        rutaActual = null;
        document.getElementById('resultadoRuta').textContent =
          'El layout cambió: vuelve a calcular la ruta.';
      }
    }
    arrastrando = null;
  };

  plano.addEventListener('pointerup', soltar);
  plano.addEventListener('pointercancel', soltar);
}

function actualizarBarraEdicion() {
  const n = racksModificados.size;
  document.getElementById('btnGuardarLayout').hidden = n === 0;
  document.getElementById('btnDescartarLayout').hidden = n === 0;
  document.getElementById('estadoEdicion').textContent =
    n === 0 ? 'Arrastra los racks para acomodarlos como están en la realidad.'
            : `${n} rack${n === 1 ? '' : 's'} movido${n === 1 ? '' : 's'} sin guardar.`;
}

document.getElementById('btnModoEdicion').addEventListener('click', () => {
  modoEdicion = !modoEdicion;
  document.getElementById('btnModoEdicion').textContent = modoEdicion ? 'Salir del editor' : 'Editar plano';
  document.getElementById('btnModoEdicion').setAttribute('aria-pressed', String(modoEdicion));
  document.getElementById('barraEdicion').hidden = !modoEdicion;
  if (!modoEdicion) {
    rackSeleccionado = null;
    document.getElementById('panelRack').hidden = true;
  }
  actualizarPanelAlmacen();
  actualizarBarraEdicion();
  renderPlano(document.getElementById('filtroMapaAlmacen').value, todoElMapa);
});

document.getElementById('btnDescartarLayout').addEventListener('click', () => {
  racksModificados.clear();
  actualizarBarraEdicion();
  renderPlano(document.getElementById('filtroMapaAlmacen').value, todoElMapa);
});

document.getElementById('btnGuardarLayout').addEventListener('click', async () => {
  const boton = document.getElementById('btnGuardarLayout');
  boton.disabled = true;
  boton.textContent = 'Guardando…';

  try {
    for (const [rackId, geometria] of racksModificados) {
      await InventarioAPI.actualizarGeometriaRack(rackId, geometria);
      // Se refleja en la copia local para no tener que recargar todo.
      const rack = layoutRacks.find((r) => r.id === rackId);
      if (rack) {
        rack.grid_x = geometria.gridX;
        rack.grid_y = geometria.gridY;
        rack.grid_ancho = geometria.gridAncho;
        rack.grid_alto = geometria.gridAlto;
      }
    }
    racksModificados.clear();
    mostrarToast('Layout guardado.', 'ok');
  } catch (err) {
    // Los errores de solape o de "se sale del plano" vienen del trigger de la
    // base con su texto original: se muestran tal cual.
    mostrarToast(err.message ?? 'No se pudo guardar el layout.', 'bad');
  } finally {
    boton.disabled = false;
    boton.textContent = 'Guardar layout';
    actualizarBarraEdicion();
    renderPlano(document.getElementById('filtroMapaAlmacen').value, todoElMapa);
  }
});

// =============================================================================
//  RUTA MÁS CORTA
// =============================================================================

function poblarSelectsRuta(almacenCode) {
  const destinoSel = document.getElementById('campoRutaDestino');
  const boton = document.getElementById('btnCalcularRuta');

  if (!almacenCode) {
    destinoSel.innerHTML = '<option value="">Elige un almacén arriba ↑</option>';
    boton.disabled = true;
    return;
  }

  const almacen = almacenPorCodigo(almacenCode);
  if (!almacen) return;

  boton.disabled = false;
  const previo = destinoSel.value;
  destinoSel.innerHTML = '';
  for (const rack of racksDe(almacen.id)) {
    const opt = document.createElement('option');
    opt.value = rack.id;
    opt.textContent = rack.code;
    destinoSel.appendChild(opt);
  }
  if ([...destinoSel.options].some((o) => o.value === previo)) destinoSel.value = previo;
}

document.getElementById('btnCalcularRuta').addEventListener('click', () => {
  const almacenCode = document.getElementById('filtroMapaAlmacen').value;
  const rackId = document.getElementById('campoRutaDestino').value;
  const resultadoEl = document.getElementById('resultadoRuta');

  const almacen = almacenPorCodigo(almacenCode);
  const rack = layoutRacks.find((r) => r.id === rackId);
  if (!almacen || !rack) {
    resultadoEl.textContent = 'Elige un almacén y un rack de destino.';
    return;
  }

  const racks = racksDe(almacen.id);
  const grilla = construirGrilla(almacen, racks);
  const metas = celdasDeAcceso(grilla, geometriaDe(rack));
  const resultado = calcularRutaAEstrella(grilla, [almacen.entrada_x, almacen.entrada_y], metas);

  if (!resultado) {
    resultadoEl.textContent = `No hay forma de llegar a ${rack.code}: quedó encerrado por otros racks.`;
    rutaActual = null;
  } else {
    resultadoEl.textContent =
      `Entrada → ${rack.code}: ${resultado.distancia.toFixed(1)} m recorriendo ${resultado.celdas.length} celdas.`;
    rutaActual = { almacenCode, celdas: resultado.celdas };
  }

  document.getElementById('btnLimpiarRuta').hidden = !rutaActual;
  renderPlano(almacenCode, todoElMapa);
});

document.getElementById('btnLimpiarRuta').addEventListener('click', () => {
  rutaActual = null;
  document.getElementById('resultadoRuta').textContent = '';
  document.getElementById('btnLimpiarRuta').hidden = true;
  renderPlano(document.getElementById('filtroMapaAlmacen').value, todoElMapa);
});

// =============================================================================
//  SELECCIÓN: TAMAÑO, GIRO Y ELIMINACIÓN DE UN RACK
// =============================================================================

function repintar() {
  renderPlano(document.getElementById('filtroMapaAlmacen').value, todoElMapa);
}

function seleccionarRack(rackId) {
  rackSeleccionado = rackId;
  const rack = layoutRacks.find((r) => r.id === rackId);
  if (!rack) return;

  const almacen = layoutAlmacenes.find((a) => a.id === rack.warehouse_id);
  const g = geometriaDe(rack);
  const config = configuracionDeRack(rack, almacen.code);

  document.getElementById('panelRackTitulo').textContent = rack.code;
  document.getElementById('campoRackAncho').value = g.gridAncho;
  document.getElementById('campoRackAlto').value = g.gridAlto;
  document.getElementById('campoRackNiveles').value = config.niveles;
  document.getElementById('campoRackSlots').value = config.slots;
  document.getElementById('panelRack').hidden = false;
  refrescarCapacidadPanel();
  repintar();
}

function deseleccionarRack() {
  rackSeleccionado = null;
  document.getElementById('panelRack').hidden = true;
  repintar();
}

// Lo que hay hoy vs. lo que daría la configuración escrita en el panel. La
// estimación la calcula la base (misma función que usa al grabar), así que la
// cifra que se ve acá es la que va a quedar.
async function refrescarCapacidadPanel() {
  const nota = document.getElementById('panelRackCapacidad');
  const rack = layoutRacks.find((r) => r.id === rackSeleccionado);
  if (!rack) return;

  const almacen = layoutAlmacenes.find((a) => a.id === rack.warehouse_id);
  const g = geometriaDe(rack);
  const { total, capacidad } = ocupacionDelRack(todoElMapa, almacen.code, rack.code);
  const niveles = parseInt(document.getElementById('campoRackNiveles').value, 10) || 1;
  const slots = parseInt(document.getElementById('campoRackSlots').value, 10) || 1;

  nota.textContent = `Hoy: ${total} posiciones, ${formatearNumero(capacidad)} cajas. Calculando…`;
  try {
    const est = await InventarioAPI.estimarCapacidadRack({
      gridAncho: g.gridAncho, gridAlto: g.gridAlto, niveles, slotsPorNivel: slots,
    });
    const detalle = (est.por_nivel ?? [])
      .map((n) => `n${n.nivel}: ${formatearNumero(n.cajas)}`)
      .join(' · ');
    nota.textContent =
      `Hoy: ${total} posiciones, ${formatearNumero(capacidad)} cajas. ` +
      `Con ${niveles} niveles × ${slots}: ${est.posiciones} posiciones, ${formatearNumero(est.cajas)} cajas (${detalle}).`;
  } catch (err) {
    nota.textContent = `Hoy: ${total} posiciones, ${formatearNumero(capacidad)} cajas.`;
  }
}

document.getElementById('campoRackNiveles').addEventListener('change', refrescarCapacidadPanel);
document.getElementById('campoRackSlots').addEventListener('change', refrescarCapacidadPanel);

document.getElementById('btnAplicarNivelesRack').addEventListener('click', async () => {
  const rack = layoutRacks.find((r) => r.id === rackSeleccionado);
  if (!rack) return;

  const boton = document.getElementById('btnAplicarNivelesRack');
  boton.disabled = true;
  boton.textContent = 'Aplicando…';
  try {
    const resultado = await InventarioAPI.configurarRack(rack.id, {
      niveles: parseInt(document.getElementById('campoRackNiveles').value, 10),
      slotsPorNivel: parseInt(document.getElementById('campoRackSlots').value, 10),
    });
    mostrarToast(resultado.mensaje ?? 'Rack reconfigurado.', 'ok');
    await recargarLayout();
    seleccionarRack(rack.id);
  } catch (err) {
    // "la posición X tiene historial" viene de la base con el detalle exacto.
    mostrarToast(err.message ?? 'No se pudo reconfigurar el rack.', 'bad');
  } finally {
    boton.disabled = false;
    boton.textContent = 'Aplicar niveles';
  }
});

// =============================================================================
//  TAMAÑO DEL ALMACÉN
// =============================================================================

// Solo tiene sentido con UN almacén a la vista: "aplicar 30 x 20" a los tres a
// la vez sería casi siempre un accidente.
function actualizarPanelAlmacen() {
  const panel = document.getElementById('panelAlmacen');
  const almacen = almacenPorCodigo(document.getElementById('filtroMapaAlmacen').value);

  if (!modoEdicion || !almacen) {
    panel.hidden = true;
    return;
  }
  panel.hidden = false;
  document.getElementById('panelAlmacenTitulo').textContent = almacen.name;
  document.getElementById('campoAlmacenAncho').value = almacen.grid_ancho;
  document.getElementById('campoAlmacenAlto').value = almacen.grid_alto;
  document.getElementById('panelAlmacenNota').textContent =
    `${almacen.grid_ancho * almacen.grid_alto} m² de piso. Entre 10 y 80 m por lado.`;
}

document.getElementById('filtroMapaAlmacen').addEventListener('change', actualizarPanelAlmacen);

document.getElementById('btnAplicarTamanoAlmacen').addEventListener('click', async () => {
  const almacen = almacenPorCodigo(document.getElementById('filtroMapaAlmacen').value);
  if (!almacen) return;

  const boton = document.getElementById('btnAplicarTamanoAlmacen');
  boton.disabled = true;
  boton.textContent = 'Aplicando…';
  try {
    const actualizado = await InventarioAPI.redimensionarAlmacen(almacen.code, {
      gridAncho: parseInt(document.getElementById('campoAlmacenAncho').value, 10),
      gridAlto: parseInt(document.getElementById('campoAlmacenAlto').value, 10),
    });
    Object.assign(almacen, actualizado);
    // La ruta dibujada se calculó sobre la grilla anterior.
    rutaActual = null;
    document.getElementById('btnLimpiarRuta').hidden = true;
    mostrarToast(`${almacen.name}: ${actualizado.grid_ancho} × ${actualizado.grid_alto} m.`, 'ok');
    actualizarPanelAlmacen();
    repintar();
  } catch (err) {
    // Si algún rack quedaría fuera del plano, la base los nombra.
    mostrarToast(err.message ?? 'No se pudo cambiar el tamaño del almacén.', 'bad');
    actualizarPanelAlmacen();
  } finally {
    boton.disabled = false;
    boton.textContent = 'Aplicar tamaño';
  }
});

// Cambiar el tamaño puede sacar el rack del plano; se recorta antes de
// tocarlo para que el editor no proponga algo que la base va a rechazar.
function redimensionarSeleccionado(nuevoAncho, nuevoAlto) {
  const rack = layoutRacks.find((r) => r.id === rackSeleccionado);
  if (!rack) return;
  const almacen = layoutAlmacenes.find((a) => a.id === rack.warehouse_id);
  const g = geometriaDe(rack);

  const ancho = Math.max(1, Math.min(nuevoAncho, almacen.grid_ancho - g.gridX));
  const alto = Math.max(1, Math.min(nuevoAlto, almacen.grid_alto - g.gridY));

  racksModificados.set(rack.id, { ...g, gridAncho: ancho, gridAlto: alto });
  document.getElementById('campoRackAncho').value = ancho;
  document.getElementById('campoRackAlto').value = alto;

  if (rutaActual) {
    rutaActual = null;
    document.getElementById('resultadoRuta').textContent = 'El layout cambió: vuelve a calcular la ruta.';
  }
  actualizarBarraEdicion();
  refrescarCapacidadPanel();
  repintar();
}

document.getElementById('campoRackAncho').addEventListener('change', (e) => {
  redimensionarSeleccionado(parseInt(e.target.value, 10) || 1, parseInt(document.getElementById('campoRackAlto').value, 10) || 1);
});
document.getElementById('campoRackAlto').addEventListener('change', (e) => {
  redimensionarSeleccionado(parseInt(document.getElementById('campoRackAncho').value, 10) || 1, parseInt(e.target.value, 10) || 1);
});

// Girar 90° un rectángulo alineado a los ejes es exactamente intercambiar
// ancho y largo — por eso no hay ninguna columna "orientación" que mantener:
// sería estado duplicado que se puede desincronizar.
document.getElementById('btnRotarRack').addEventListener('click', () => {
  const rack = layoutRacks.find((r) => r.id === rackSeleccionado);
  if (!rack) return;
  const g = geometriaDe(rack);
  redimensionarSeleccionado(g.gridAlto, g.gridAncho);
});

document.getElementById('btnDeseleccionarRack').addEventListener('click', deseleccionarRack);

document.getElementById('btnEliminarRack').addEventListener('click', async () => {
  const rack = layoutRacks.find((r) => r.id === rackSeleccionado);
  if (!rack) return;

  const boton = document.getElementById('btnEliminarRack');
  boton.disabled = true;
  try {
    const resultado = await InventarioAPI.eliminarRack(rack.id);
    mostrarToast(resultado.mensaje ?? 'Rack eliminado.', 'ok');
    racksModificados.delete(rack.id);
    deseleccionarRack();
    await recargarLayout();
  } catch (err) {
    // Si el rack tiene mercadería o historial, el mensaje viene de la función
    // de la base con el detalle exacto: se muestra tal cual.
    mostrarToast(err.message ?? 'No se pudo eliminar el rack.', 'bad');
  } finally {
    boton.disabled = false;
  }
});

// =============================================================================
//  CREAR UN RACK
// =============================================================================

// Busca el primer hueco donde quepa un rectángulo de ese tamaño, recorriendo
// el plano de arriba a abajo y de izquierda a derecha.
function primerHuecoLibre(almacen, ancho, alto) {
  const racks = racksDe(almacen.id).map(geometriaDe);
  for (let y = 0; y <= almacen.grid_alto - alto; y++) {
    for (let x = 0; x <= almacen.grid_ancho - ancho; x++) {
      const chocaConAlguno = racks.some(
        (g) =>
          x < g.gridX + g.gridAncho &&
          g.gridX < x + ancho &&
          y < g.gridY + g.gridAlto &&
          g.gridY < y + alto
      );
      if (!chocaConAlguno) return { x, y };
    }
  }
  return null;
}

function siguienteCodigoRack(almacen) {
  const usados = new Set(racksDe(almacen.id).map((r) => r.code));
  for (let i = 1; i <= 99; i++) {
    const codigo = `RACK-${String(i).padStart(2, '0')}`;
    if (!usados.has(codigo)) return codigo;
  }
  return '';
}

document.getElementById('btnNuevoRack').addEventListener('click', () => {
  const almacen = almacenPorCodigo(document.getElementById('filtroMapaAlmacen').value);
  if (!almacen) {
    mostrarToast('Elige primero un almacén en el filtro de arriba.', 'bad');
    return;
  }
  document.getElementById('formNuevoRack').reset();
  document.getElementById('modalRackError').hidden = true;
  document.getElementById('campoNuevoRackCodigo').value = siguienteCodigoRack(almacen);
  document.getElementById('campoNuevoRackAncho').value = 14;
  document.getElementById('campoNuevoRackAlto').value = 2;
  document.getElementById('campoNuevoRackNiveles').value = 3;
  document.getElementById('campoNuevoRackPosiciones').value = 7;
  refrescarEstimacionNuevoRack();
  mostrarModal('modalNuevoRack');
});

// Responde "¿cuánto guarda un rack así?" antes de crearlo. La cuenta la hace
// la base, que es la misma que se aplicará al grabar.
async function refrescarEstimacionNuevoRack() {
  const salida = document.getElementById('estimacionNuevoRack');
  const leer = (id) => parseInt(document.getElementById(id).value, 10) || 1;

  salida.textContent = 'Calculando capacidad…';
  try {
    const est = await InventarioAPI.estimarCapacidadRack({
      gridAncho: leer('campoNuevoRackAncho'),
      gridAlto: leer('campoNuevoRackAlto'),
      niveles: leer('campoNuevoRackNiveles'),
      slotsPorNivel: leer('campoNuevoRackPosiciones'),
    });
    const detalle = (est.por_nivel ?? [])
      .map((n) => `nivel ${n.nivel}: ${formatearNumero(n.cajas)}`)
      .join(' · ');
    salida.textContent = `${est.posiciones} posiciones · ${formatearNumero(est.cajas)} cajas — ${detalle}`;
  } catch (err) {
    salida.textContent = '';
  }
}

['campoNuevoRackAncho', 'campoNuevoRackAlto', 'campoNuevoRackNiveles', 'campoNuevoRackPosiciones']
  .forEach((id) => document.getElementById(id).addEventListener('change', refrescarEstimacionNuevoRack));

const cerrarModalRack = () => ocultarModal('modalNuevoRack');
document.getElementById('btnCerrarModalRack').addEventListener('click', cerrarModalRack);
document.getElementById('btnCancelarNuevoRack').addEventListener('click', cerrarModalRack);
document.getElementById('modalNuevoRack').addEventListener('click', (e) => {
  if (e.target.id === 'modalNuevoRack') cerrarModalRack();
});

document.getElementById('formNuevoRack').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  const boton = document.getElementById('btnGuardarNuevoRack');
  const errorEl = document.getElementById('modalRackError');
  errorEl.hidden = true;
  boton.disabled = true;
  boton.textContent = 'Creando…';

  try {
    const almacen = almacenPorCodigo(document.getElementById('filtroMapaAlmacen').value);
    if (!almacen) throw new Error('Elige un almacén antes de crear un rack.');

    const ancho = parseInt(document.getElementById('campoNuevoRackAncho').value, 10);
    const alto = parseInt(document.getElementById('campoNuevoRackAlto').value, 10);
    const hueco = primerHuecoLibre(almacen, ancho, alto);
    if (!hueco) throw new Error(`No queda espacio en el plano para un rack de ${ancho} × ${alto} m.`);

    await InventarioAPI.crearRack({
      warehouseCode: almacen.code,
      code: document.getElementById('campoNuevoRackCodigo').value.trim().toUpperCase(),
      gridX: hueco.x,
      gridY: hueco.y,
      gridAncho: ancho,
      gridAlto: alto,
      niveles: parseInt(document.getElementById('campoNuevoRackNiveles').value, 10),
      slotsPorNivel: parseInt(document.getElementById('campoNuevoRackPosiciones').value, 10),
    });

    cerrarModalRack();
    mostrarToast('Rack creado. Arrástralo a su lugar en el plano.', 'ok');
    await recargarLayout();
  } catch (err) {
    errorEl.textContent = err.message ?? 'No se pudo crear el rack.';
    errorEl.hidden = false;
    errorEl.focus();
  } finally {
    boton.disabled = false;
    boton.textContent = 'Crear rack';
  }
});

// Vuelve a traer la geometría después de crear o eliminar un rack. Se trae
// también el mapa de posiciones porque un rack nuevo llega con las suyas.
async function recargarLayout() {
  const [layout, mapa] = await Promise.all([
    InventarioAPI.obtenerLayout(),
    InventarioAPI.obtenerMapaAlmacen(),
  ]);
  inicializarLayout(layout);
  inicializarMapa(mapa); // ya repinta el plano y el detalle
}
