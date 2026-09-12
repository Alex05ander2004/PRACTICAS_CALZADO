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
let entradaModificada = new Map(); // almacenId -> { x, y }
let rackSeleccionado = null;      // id del rack cuyo panel de propiedades está abierto
let rackAbierto = null;           // rack cuyo frente se ve en el panel lateral (fuera del modo edición)

function inicializarLayout(layout) {
  layoutAlmacenes = layout.almacenes;
  layoutRacks = layout.racks;
  poblarSelectsDeAlmacen();
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

// Lo mismo que geometriaDe, para la puerta.
function entradaDe(almacen) {
  return entradaModificada.get(almacen.id) ?? { x: almacen.entrada_x, y: almacen.entrada_y };
}

// Una puerta en medio del piso no es una puerta: el punto se lleva siempre a
// la pared más cercana. Espejo exacto de fn_pegar_a_pared (migración 12), que
// es la que manda al grabar.
function pegarAPared(x, y, ancho, alto) {
  const cx = Math.min(Math.max(x, 0), ancho - 1);
  const cy = Math.min(Math.max(y, 0), alto - 1);
  const distancias = { izquierda: cx, derecha: ancho - 1 - cx, arriba: cy, abajo: alto - 1 - cy };
  const pared = Object.keys(distancias).reduce((a, b) => (distancias[b] < distancias[a] ? b : a));

  if (pared === 'izquierda') return { x: 0, y: cy, pared };
  if (pared === 'derecha') return { x: ancho - 1, y: cy, pared };
  if (pared === 'arriba') return { x: cx, y: 0, pared };
  return { x: cx, y: alto - 1, pared };
}

function celdaTapadaPorRack(almacen, x, y) {
  return racksDe(almacen.id).some((rack) => {
    const g = geometriaDe(rack);
    return x >= g.gridX && x < g.gridX + g.gridAncho &&
           y >= g.gridY && y < g.gridY + g.gridAlto;
  });
}

// Nada se pone encima de la entrada. Si la celda de la pared la ocupa un rack
// el arrastre no avanza hasta ahí: la puerta se queda en el último lugar
// válido. No se la reubica sola a otro punto — eso sería moverla a un sitio
// que nadie eligió.
function puertaValida(almacen, x, y) {
  const punto = pegarAPared(x, y, almacen.grid_ancho, almacen.grid_alto);
  return celdaTapadaPorRack(almacen, punto.x, punto.y) ? null : punto;
}

// La orientación de la entrada no se guarda en ninguna columna: sale de en qué
// pared quedó, igual que el giro de un rack sale de su ancho y su largo. En las
// paredes laterales el rótulo se escribe en vertical (lo hace el CSS) y se
// apoya contra el borde para no quedar cortado por el overflow del plano.
function posicionarEntrada(el, almacen, x, y) {
  const { pared } = pegarAPared(x, y, almacen.grid_ancho, almacen.grid_alto);
  el.classList.remove(
    'plano-entrada--arriba', 'plano-entrada--abajo',
    'plano-entrada--izquierda', 'plano-entrada--derecha'
  );
  el.classList.add(`plano-entrada--${pared}`);

  if (pared === 'arriba' || pared === 'abajo') {
    el.style.left = `${((x + 0.5) / almacen.grid_ancho) * 100}%`;
    el.style.top = pared === 'arriba' ? '0%' : '100%';
  } else {
    el.style.top = `${((y + 0.5) / almacen.grid_alto) * 100}%`;
    el.style.left = pared === 'izquierda' ? '0%' : '100%';
  }
}

// La ruta dibujada se calculó sobre un layout que ya no es el que se ve.
function invalidarRuta() {
  if (!rutaActual) return;
  rutaActual = null;
  document.getElementById('btnLimpiarRuta').hidden = true;
  document.getElementById('resultadoRuta').textContent = 'El layout cambió: vuelve a calcular la ruta.';
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
  // Una fila por talla ubicada (migración 20): el casillero se cuenta una vez,
  // con su capacidad una vez, y las cajas de todas sus tallas.
  const porCasillero = new Map();
  for (const f of mapaFilas) {
    if (f.almacen_code !== almacenCode || f.rack !== rackCode) continue;
    const c = porCasillero.get(f.position_id) ?? { capacidad: f.capacity_units ?? 0, ocupado: 0 };
    c.ocupado += f.unidades ?? 0;
    porCasillero.set(f.position_id, c);
  }
  const lista = [...porCasillero.values()];
  return {
    total: lista.length,
    libres: lista.filter((c) => c.ocupado === 0).length,
    capacidad: lista.reduce((suma, c) => suma + c.capacidad, 0),
    ocupado: lista.reduce((suma, c) => suma + c.ocupado, 0),
  };
}

// Cómo está repartido HOY un rack en pisos y casilleros. Los niveles salen de
// la columna del rack (es una propiedad del mueble); las posiciones por nivel
// se cuentan, porque un rack heredado puede tener unos niveles mapeados y
// otros todavía no.
function configuracionDeRack(rack, almacenCode) {
  const posiciones = todoElMapa.filter((f) => f.almacen_code === almacenCode && f.rack === rack.code);
  const porNivel = new Map();
  const vistos = new Set(); // una fila por talla ubicada: el casillero se cuenta una vez
  for (const f of posiciones) {
    if (vistos.has(f.position_id)) continue;
    vistos.add(f.position_id);
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
  // El CSS necesita la forma del local para decidir si lo que limita el tamaño
  // es el ancho de la pantalla o su alto (ver .plano-piso).
  plano.style.setProperty('--plano-ratio', almacen.grid_ancho / almacen.grid_alto);
  plano.style.setProperty('--plano-cols', almacen.grid_ancho);
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
    if (!modoEdicion && rackAbierto === rack.id) el.classList.add('abierto');
    el.dataset.rackId = rack.id;
    el.style.left = pct(g.gridX, almacen.grid_ancho);
    el.style.top = pct(g.gridY, almacen.grid_alto);
    el.style.width = pct(g.gridAncho, almacen.grid_ancho);
    el.style.height = pct(g.gridAlto, almacen.grid_alto);
    el.title =
      `${rack.code} — ${g.gridAncho} × ${g.gridAlto} m, ${rack.niveles ?? 1} niveles\n` +
      `${libres} de ${total} posiciones libres\n` +
      `${formatearNumero(ocupado)} de ${formatearNumero(capacidad)} cajas` +
      (modoEdicion ? '\n(arrastra para mover)' : '\n(clic para ver su contenido)');
    el.innerHTML = `<span class="plano-rack-etiqueta">${rack.code}</span>`;
    plano.appendChild(el);
  }

  // Entrada
  const puerta = entradaDe(almacen);
  const entrada = document.createElement('div');
  entrada.className = 'plano-entrada';
  if (entradaModificada.has(almacen.id)) entrada.classList.add('modificado');
  entrada.title = modoEdicion
    ? 'Entrada del almacén (arrástrala por las paredes)'
    : 'Entrada del almacén';
  entrada.textContent = 'Entrada';
  posicionarEntrada(entrada, almacen, puerta.x, puerta.y);
  plano.appendChild(entrada);

  bloque.appendChild(plano);
  if (modoEdicion) {
    habilitarArrastre(plano, almacen);
  } else {
    plano.addEventListener('click', (e) => {
      const rackEl = e.target.closest('.plano-rack');
      if (rackEl) abrirContenidoRack(rackEl.dataset.rackId);
    });
  }
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
  let arrastrandoEntrada = null;

  plano.addEventListener('pointerdown', (e) => {
    // La puerta se arrastra igual que un rack, pero solo recorre el perímetro.
    const entradaEl = e.target.closest('.plano-entrada');
    if (entradaEl) {
      e.preventDefault();
      entradaEl.setPointerCapture(e.pointerId);
      arrastrandoEntrada = { el: entradaEl, caja: plano.getBoundingClientRect() };
      entradaEl.classList.add('arrastrando');
      return;
    }

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
    if (arrastrandoEntrada) {
      const { caja, el } = arrastrandoEntrada;
      const x = Math.round((e.clientX - caja.left) / (caja.width / almacen.grid_ancho) - 0.5);
      const y = Math.round((e.clientY - caja.top) / (caja.height / almacen.grid_alto) - 0.5);
      const punto = puertaValida(almacen, x, y);
      if (!punto) return; // celda ocupada: la puerta no se mueve ahí
      arrastrandoEntrada.punto = punto;
      posicionarEntrada(el, almacen, punto.x, punto.y);
      return;
    }

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
    if (arrastrandoEntrada) {
      const { el, punto } = arrastrandoEntrada;
      el.classList.remove('arrastrando');
      arrastrandoEntrada = null;
      if (punto) {
        entradaModificada.set(almacen.id, { x: punto.x, y: punto.y });
        el.classList.add('modificado');
        invalidarRuta();
        actualizarBarraEdicion();
      }
      return;
    }

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
      invalidarRuta();
    }
    arrastrando = null;
  };

  plano.addEventListener('pointerup', soltar);
  plano.addEventListener('pointercancel', soltar);
}

function hayCambiosPendientes() {
  return racksModificados.size > 0 || entradaModificada.size > 0;
}

function actualizarBarraEdicion() {
  const n = racksModificados.size;
  const puertas = entradaModificada.size;
  const hayCambios = hayCambiosPendientes();

  document.getElementById('btnGuardarLayout').hidden = !hayCambios;
  document.getElementById('btnDescartarLayout').hidden = !hayCambios;

  const partes = [];
  if (n > 0) partes.push(`${n} rack${n === 1 ? '' : 's'} movido${n === 1 ? '' : 's'}`);
  if (puertas > 0) partes.push(`${puertas} entrada${puertas === 1 ? '' : 's'} movida${puertas === 1 ? '' : 's'}`);

  document.getElementById('estadoEdicion').textContent = hayCambios
    ? `${partes.join(' y ')} sin guardar.`
    : 'Arrastra los racks para acomodarlos como están en la realidad. La entrada se mueve igual, pero solo por las paredes.';
}

document.getElementById('btnModoEdicion').addEventListener('click', () => {
  // Editar y mirar el contenido son modos distintos: el clic en un rack
  // selecciona para mover en uno y abre el frente en el otro.
  if (rackAbierto) cerrarContenidoRack();
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
  entradaModificada.clear();
  actualizarBarraEdicion();
  renderPlano(document.getElementById('filtroMapaAlmacen').value, todoElMapa);
});

document.getElementById('btnGuardarLayout').addEventListener('click', async () => {
  const boton = document.getElementById('btnGuardarLayout');
  boton.disabled = true;
  boton.textContent = 'Guardando…';

  try {
    // Cada entrada se borra del pendiente apenas se graba: si una falla, las
    // ya guardadas no se vuelven a mandar al reintentar.
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
      racksModificados.delete(rackId);
    }

    for (const [almacenId, punto] of entradaModificada) {
      const almacen = layoutAlmacenes.find((a) => a.id === almacenId);
      Object.assign(almacen, await InventarioAPI.moverEntradaAlmacen(almacen.code, punto));
      entradaModificada.delete(almacenId);
    }

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

// =============================================================================
//  RECORRIDO POR VARIOS RACKS
// =============================================================================
// Un picking real casi nunca es "ir a un rack y volver": es una vuelta que pasa
// por varios. El orden lo decide el sistema, porque es justo donde se gana o se
// pierde distancia — visitar tres racks en el peor orden puede costar el doble
// que en el mejor, y esa diferencia la camina una persona con un carrito.

// Más de esto y las permutaciones dejan de ser instantáneas (8! = 40 320, que
// todavía va sobrado; 10! ya son 3,6 millones). Con el tope puesto acá se puede
// prometer el recorrido MÁS corto y no "uno bastante bueno".
const MAX_PARADAS_RUTA = 8;

function poblarSelectsRuta(almacenCode) {
  const lista = document.getElementById('listaParadasRuta');
  const boton = document.getElementById('btnCalcularRuta');

  if (!almacenCode) {
    lista.innerHTML = '<p class="ruta-paradas-vacio">Elige un almacén arriba ↑</p>';
    boton.disabled = true;
    return;
  }

  const almacen = almacenPorCodigo(almacenCode);
  if (!almacen) return;

  // Se conserva lo que ya estaba marcado: cambiar de tamaño el plano o mover un
  // rack repuebla esta lista, y perder la selección en cada repintado sería
  // insufrible.
  const marcados = new Set(paradasElegidas());
  const racks = racksDe(almacen.id);

  lista.innerHTML = '';
  if (racks.length === 0) {
    lista.innerHTML = '<p class="ruta-paradas-vacio">Este almacén todavía no tiene racks.</p>';
    boton.disabled = true;
    return;
  }

  for (const rack of racks) {
    const id = `parada-${rack.id}`;
    const label = document.createElement('label');
    label.className = 'ruta-parada';
    label.innerHTML = `<input type="checkbox" id="${id}" value="${rack.id}" /> <span></span>`;
    label.querySelector('span').textContent = rack.code;
    label.querySelector('input').checked = marcados.has(rack.id);
    lista.appendChild(label);
  }
  boton.disabled = false;
}

function paradasElegidas() {
  return [...document.querySelectorAll('#listaParadasRuta input:checked')].map((c) => c.value);
}

// Un tramo del recorrido: del punto donde estoy a la celda de acceso más
// cercana del rack destino. Devuelve también dónde termina, porque ahí empieza
// el tramo siguiente.
function tramoHasta(grilla, desde, rack) {
  const metas = celdasDeAcceso(grilla, geometriaDe(rack));
  const r = calcularRutaAEstrella(grilla, desde, metas);
  return r && { celdas: r.celdas, distancia: r.distancia, fin: r.celdas[r.celdas.length - 1] };
}

// Recorre las paradas en el orden dado, encadenando los tramos: cada uno arranca
// donde terminó el anterior. Devuelve null si alguna quedó inalcanzable.
function recorrerEnOrden(grilla, inicio, racksEnOrden) {
  let desde = inicio;
  let total = 0;
  const celdas = [inicio];

  for (const rack of racksEnOrden) {
    const tramo = tramoHasta(grilla, desde, rack);
    if (!tramo) return { inalcanzable: rack };
    total += tramo.distancia;
    celdas.push(...tramo.celdas.slice(1)); // sin repetir la celda de empalme
    desde = tramo.fin;
  }
  return { celdas, distancia: total };
}

function* permutaciones(items) {
  if (items.length <= 1) { yield items; return; }
  for (let i = 0; i < items.length; i++) {
    const resto = [...items.slice(0, i), ...items.slice(i + 1)];
    for (const p of permutaciones(resto)) yield [items[i], ...p];
  }
}

// Prueba todos los órdenes posibles y se queda con el más corto. Cada orden se
// evalúa recorriéndolo de verdad, no sobre una matriz de distancias
// precalculada: de qué celda del rack sales cambia según de dónde vengas, y una
// matriz fija daría un orden óptimo para un recorrido que no es el que se dibuja.
function mejorRecorrido(grilla, inicio, racks) {
  let mejor = null;
  for (const orden of permutaciones(racks)) {
    const r = recorrerEnOrden(grilla, inicio, orden);
    if (r.inalcanzable) return r;
    if (!mejor || r.distancia < mejor.distancia) mejor = { ...r, orden };
  }
  return mejor;
}

document.getElementById('btnCalcularRuta').addEventListener('click', () => {
  const almacenCode = document.getElementById('filtroMapaAlmacen').value;
  const resultadoEl = document.getElementById('resultadoRuta');
  const almacen = almacenPorCodigo(almacenCode);
  if (!almacen) {
    resultadoEl.textContent = 'Elige un almacén arriba.';
    return;
  }

  const ids = paradasElegidas();
  if (ids.length === 0) {
    resultadoEl.textContent = 'Marca al menos un rack para armar el recorrido.';
    return;
  }
  if (ids.length > MAX_PARADAS_RUTA) {
    resultadoEl.textContent =
      `De a ${MAX_PARADAS_RUTA} racks como máximo: con más, encontrar el orden realmente más corto deja de ser instantáneo. Marcaste ${ids.length}.`;
    return;
  }

  const racks = ids.map((id) => layoutRacks.find((r) => r.id === id)).filter(Boolean);
  const grilla = construirGrilla(almacen, racksDe(almacen.id));
  const puerta = entradaDe(almacen);
  const resultado = mejorRecorrido(grilla, [puerta.x, puerta.y], racks);

  if (resultado?.inalcanzable) {
    resultadoEl.textContent = `No hay forma de llegar a ${resultado.inalcanzable.code}: quedó encerrado por otros racks.`;
    rutaActual = null;
  } else if (!resultado) {
    resultadoEl.textContent = 'No se pudo calcular el recorrido.';
    rutaActual = null;
  } else {
    const paso = ['Entrada', ...resultado.orden.map((r) => r.code)].join(' → ');
    resultadoEl.textContent =
      `${paso}: ${resultado.distancia.toFixed(1)} m recorriendo ${resultado.celdas.length} celdas.`;
    rutaActual = { almacenCode, celdas: resultado.celdas };
  }

  document.getElementById('btnLimpiarRuta').hidden = !rutaActual;
  renderPlano(almacenCode, todoElMapa);
});

document.getElementById('btnLimpiarRuta').addEventListener('click', () => {
  rutaActual = null;
  document.getElementById('btnLimpiarRuta').hidden = true;
  document.getElementById('resultadoRuta').textContent = '';
  document.querySelectorAll('#listaParadasRuta input:checked').forEach((c) => { c.checked = false; });
  repintar();
});

document.getElementById('listaParadasRuta').addEventListener('change', () => {
  // La ruta dibujada ya no corresponde a lo que está marcado.
  if (rutaActual) invalidarRuta();
});

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

  const hoy = `Hoy: ${total} casilleros, ${formatearNumero(capacidad)} cajas.`;
  nota.textContent = `${hoy} Calculando…`;
  try {
    // Sin cantidad de casilleros: la base propone, nivel por nivel, la que deja
    // cada uno del tamaño de un modelo (migración 21).
    const est = await InventarioAPI.estimarCapacidadRack({
      gridAncho: g.gridAncho, gridAlto: g.gridAlto, niveles, slotsPorNivel: null,
    });
    // Cada nivel dice con qué objetivo se calculó: la regla es la misma para
    // todos, los datos no — niño y adulto usan caja y modelo distintos.
    const detalle = (est.por_nivel ?? [])
      .map((n) => `n${n.nivel}${n.publico ? ' ' + n.publico : ''}: ${n.casilleros} de ${n.ancho_cm} cm, ` +
                  `${formatearNumero(n.cajas_por_casillero)} c/u` + (n.objetivo ? ` (un modelo ≈ ${n.objetivo})` : ''))
      .join(' · ');
    nota.textContent = `${hoy} A medida de un modelo: ${est.posiciones} casilleros, ${formatearNumero(est.cajas)} cajas — ${detalle}.`;
  } catch (err) {
    nota.textContent = hoy;
  }
}

document.getElementById('campoRackNiveles').addEventListener('change', refrescarCapacidadPanel);

document.getElementById('btnAplicarNivelesRack').addEventListener('click', async () => {
  const rack = layoutRacks.find((r) => r.id === rackSeleccionado);
  if (!rack) return;

  const boton = document.getElementById('btnAplicarNivelesRack');
  boton.disabled = true;
  boton.textContent = 'Aplicando…';
  try {
    const resultado = await InventarioAPI.configurarRack(rack.id, {
      niveles: parseInt(document.getElementById('campoRackNiveles').value, 10),
      slotsPorNivel: null, // a medida de un modelo (migración 21)
    });
    mostrarToast(resultado.mensaje ?? 'Rack reconfigurado.', 'ok');
    await recargarLayout();
    seleccionarRack(rack.id);
  } catch (err) {
    // "la posición X tiene historial" viene de la base con el detalle exacto.
    mostrarToast(err.message ?? 'No se pudo reconfigurar el rack.', 'bad');
  } finally {
    boton.disabled = false;
    boton.textContent = 'Aplicar niveles y casilleros';
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

// Los cambios sin guardar son de UN almacén. Si se pudiera cambiar de almacén
// arrastrándolos, "Guardar layout" mandaría también los del otro, y un rack
// mal puesto allá bloquearía lo que se acaba de acomodar acá. Antes de cambiar
// hay que resolverlos.
let almacenEnVista = '';

// El listener va en CAPTURA sobre document a propósito. Los listeners del
// propio <select> corren en orden de registro y el de mapa-modal.js se
// registra primero, así que un listener normal llegaría tarde: el plano ya se
// habría repintado con el otro almacén antes de preguntar nada. En la fase de
// captura este corre antes que todos ellos y puede frenar el cambio.
document.addEventListener('change', (evento) => {
  if (evento.target.id !== 'filtroMapaAlmacen') return;

  if (!hayCambiosPendientes()) {
    almacenEnVista = evento.target.value;
    return;
  }

  const destino = evento.target.value;
  evento.stopPropagation();

  // Se deshace la selección hasta que el usuario decida qué hacer.
  evento.target.value = almacenEnVista;
  confirmarDescartarYCambiar(destino);
}, true);

function confirmarDescartarYCambiar(destino) {
  const n = racksModificados.size + entradaModificada.size;
  const nombre = almacenPorCodigo(destino)?.name ?? 'todos los almacenes';

  document.getElementById('modalConfirmarTitulo').textContent = 'Cambios sin guardar';
  document.getElementById('modalConfirmarMensaje').textContent =
    `Hay ${n} cambio${n === 1 ? '' : 's'} sin guardar en este plano. Si pasas a ${nombre} se descartan. ` +
    'Si prefieres conservarlos, cancela y usa "Guardar layout".';

  const btnViejo = document.getElementById('btnAceptarConfirmar');
  const aceptar = btnViejo.cloneNode(true); // limpia listeners de una confirmación anterior
  aceptar.textContent = 'Descartar y cambiar';
  btnViejo.replaceWith(aceptar);

  aceptar.addEventListener('click', () => {
    racksModificados.clear();
    entradaModificada.clear();
    deseleccionarRack();
    actualizarBarraEdicion();
    ocultarModal('modalConfirmar');

    const select = document.getElementById('filtroMapaAlmacen');
    select.value = destino;
    almacenEnVista = destino;
    aplicarFiltroMapa();
    actualizarPanelAlmacen();
  }, { once: true });

  mostrarModal('modalConfirmar');
}

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
// Espejo de la regla de fn_validar_geometria_rack (migración 20): una
// estantería tiene 1 m de fondo (una cara) o 2 m (dos espalda con espalda), y
// su frente mide al menos el doble. Se revisa acá para no proponer en el
// editor un rack que la base va a rechazar al guardar.
function problemaDeForma(ancho, alto) {
  const fondo = Math.min(ancho, alto);
  const frente = Math.max(ancho, alto);
  if (fondo > 2) {
    return `Un rack de ${ancho} × ${alto} m tendría ${fondo} m de fondo: una estantería tiene 1 m (una cara) o 2 m (dos espalda con espalda), lo que se alcanza desde el pasillo.`;
  }
  if (frente < 2 * fondo) {
    return `Un rack de ${ancho} × ${alto} m no es una estantería: el frente tiene que medir al menos el doble que el fondo.`;
  }
  return null;
}

function redimensionarSeleccionado(nuevoAncho, nuevoAlto) {
  const rack = layoutRacks.find((r) => r.id === rackSeleccionado);
  if (!rack) return;
  const almacen = layoutAlmacenes.find((a) => a.id === rack.warehouse_id);
  const g = geometriaDe(rack);

  const ancho = Math.max(1, Math.min(nuevoAncho, almacen.grid_ancho - g.gridX));
  const alto = Math.max(1, Math.min(nuevoAlto, almacen.grid_alto - g.gridY));

  const problema = problemaDeForma(ancho, alto);
  if (problema) {
    mostrarToast(problema, 'bad');
    document.getElementById('campoRackAncho').value = g.gridAncho;
    document.getElementById('campoRackAlto').value = g.gridAlto;
    return;
  }

  racksModificados.set(rack.id, { ...g, gridAncho: ancho, gridAlto: alto });
  document.getElementById('campoRackAncho').value = ancho;
  document.getElementById('campoRackAlto').value = alto;

  invalidarRuta();
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
  refrescarEstimacionNuevoRack();
  mostrarModal('modalNuevoRack');
});

// Responde "¿cuánto guarda un rack así?" antes de crearlo. La cuenta la hace
// la base, que es la misma que se aplicará al grabar.
async function refrescarEstimacionNuevoRack() {
  const salida = document.getElementById('estimacionNuevoRack');
  const leer = (id) => parseInt(document.getElementById(id).value, 10) || 1;

  salida.textContent = 'Calculando casilleros…';
  try {
    const est = await InventarioAPI.estimarCapacidadRack({
      gridAncho: leer('campoNuevoRackAncho'),
      gridAlto: leer('campoNuevoRackAlto'),
      niveles: leer('campoNuevoRackNiveles'),
      slotsPorNivel: null,
    });
    const detalle = (est.por_nivel ?? [])
      .map((n) => `nivel ${n.nivel}${n.publico ? ` (${n.publico}, caja ${n.caja_cm} cm)` : ''}: ` +
                  `${n.casilleros} de ${n.ancho_cm} cm, ${formatearNumero(n.cajas_por_casillero)} c/u` +
                  (n.objetivo ? `, un modelo ≈ ${n.objetivo}` : ''))
      .join(' · ');
    salida.textContent = `${est.posiciones} casilleros · ${formatearNumero(est.cajas)} cajas — ${detalle}`;
  } catch (err) {
    salida.textContent = '';
  }
}

['campoNuevoRackAncho', 'campoNuevoRackAlto', 'campoNuevoRackNiveles']
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
    const problema = primerErrorDelFormulario(evento.target);
    if (problema) throw new Error(problema);

    const almacen = almacenPorCodigo(document.getElementById('filtroMapaAlmacen').value);
    if (!almacen) throw new Error('Elige un almacén antes de crear un rack.');

    const ancho = parseInt(document.getElementById('campoNuevoRackAncho').value, 10);
    const alto = parseInt(document.getElementById('campoNuevoRackAlto').value, 10);
    const formaInvalida = problemaDeForma(ancho, alto);
    if (formaInvalida) throw new Error(formaInvalida);
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
      slotsPorNivel: null, // a medida de un modelo (migración 21)
    });

    cerrarModalRack();
    mostrarToast('Rack creado. Arrástralo a su lugar en el plano.', 'ok');
    await recargarLayout();
  } catch (err) {
    errorEl.textContent = traducirError(err, 'No se pudo crear el rack.');
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


// =============================================================================
//  CREAR Y ELIMINAR ALMACENES
// =============================================================================

// Los <select> de almacén estaban escritos a mano en el HTML con los tres del
// seed. Poblarlos desde la lista real es lo que hace que crear un almacén
// sirva de algo: sin esto el almacén nuevo existiria en la base y en ninguna
// pantalla. Se usa new Option() y no innerHTML porque el nombre lo escribe un
// usuario y ahi entraria como markup.
function poblarSelectsDeAlmacen() {
  const conTodos = { filtroMapaAlmacen: 'Almacén: todos' };

  for (const id of ['filtroMapaAlmacen', 'campoAlmacen', 'campoUbicAlmacen']) {
    const select = document.getElementById(id);
    if (!select) continue;

    const anterior = select.value;
    const placeholder = conTodos[id];
    select.innerHTML = '';
    if (placeholder) select.add(new Option(placeholder, ''));
    for (const almacen of layoutAlmacenes) select.add(new Option(almacen.name, almacen.code));

    // Si el almacén que estaba elegido sigue existiendo se conserva; si lo
    // acaban de borrar, cae al placeholder o al primero de la lista.
    const sigueVivo = layoutAlmacenes.some((a) => a.code === anterior);
    select.value = sigueVivo ? anterior : (placeholder ? '' : (layoutAlmacenes[0]?.code ?? ''));
    sincronizarSelectMejorado(id);
  }

  almacenEnVista = document.getElementById('filtroMapaAlmacen').value;
  document.getElementById('contextoAlmacenes').textContent =
    layoutAlmacenes.map((a) => a.name).join(' · ');
}

const cerrarModalAlmacen = () => ocultarModal('modalNuevoAlmacen');
document.getElementById('btnCerrarModalAlmacen').addEventListener('click', cerrarModalAlmacen);
document.getElementById('btnCancelarNuevoAlmacen').addEventListener('click', cerrarModalAlmacen);
document.getElementById('modalNuevoAlmacen').addEventListener('click', (e) => {
  if (e.target.id === 'modalNuevoAlmacen') cerrarModalAlmacen();
});

function refrescarEstimacionAlmacen() {
  const leer = (id) => parseInt(document.getElementById(id).value, 10) || 0;
  const ancho = leer('campoNuevoAlmacenAncho');
  const alto = leer('campoNuevoAlmacenAlto');
  document.getElementById('estimacionNuevoAlmacen').textContent =
    `${formatearNumero(ancho * alto)} m² de piso.`;
}

['campoNuevoAlmacenAncho', 'campoNuevoAlmacenAlto']
  .forEach((id) => document.getElementById(id).addEventListener('input', refrescarEstimacionAlmacen));

document.getElementById('btnNuevoAlmacen').addEventListener('click', () => {
  document.getElementById('formNuevoAlmacen').reset();
  document.getElementById('modalAlmacenError').hidden = true;
  refrescarEstimacionAlmacen();
  mostrarModal('modalNuevoAlmacen');
});

document.getElementById('formNuevoAlmacen').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  const boton = document.getElementById('btnGuardarNuevoAlmacen');
  const errorEl = document.getElementById('modalAlmacenError');
  errorEl.hidden = true;
  boton.disabled = true;
  boton.textContent = 'Creando…';

  try {
    const problema = primerErrorDelFormulario(evento.target);
    if (problema) throw new Error(problema);

    const creado = await InventarioAPI.crearAlmacen({
      code: document.getElementById('campoNuevoAlmacenCodigo').value.trim(),
      name: document.getElementById('campoNuevoAlmacenNombre').value.trim(),
      address: document.getElementById('campoNuevoAlmacenDireccion').value.trim() || null,
      gridAncho: parseInt(document.getElementById('campoNuevoAlmacenAncho').value, 10),
      gridAlto: parseInt(document.getElementById('campoNuevoAlmacenAlto').value, 10),
    });

    cerrarModalAlmacen();
    await recargarLayout();

    // Se abre el almacén recién creado: es lo único que se puede hacer con él,
    // y el plano vacío deja claro que el siguiente paso es poner racks.
    const select = document.getElementById('filtroMapaAlmacen');
    select.value = creado.code;
    almacenEnVista = creado.code;
    sincronizarSelectMejorado('filtroMapaAlmacen');
    aplicarFiltroMapa();
    actualizarPanelAlmacen();

    mostrarToast(`${creado.name} creado (${creado.grid_ancho} × ${creado.grid_alto} m). Agrégale racks.`, 'ok');
  } catch (err) {
    errorEl.textContent = traducirError(err, 'No se pudo crear el almacén.');
    errorEl.hidden = false;
    errorEl.focus();
  } finally {
    boton.disabled = false;
    boton.textContent = 'Crear almacén';
  }
});

document.getElementById('btnEliminarAlmacen').addEventListener('click', () => {
  const almacen = almacenPorCodigo(document.getElementById('filtroMapaAlmacen').value);
  if (!almacen) return;

  // Con racks dentro no se abre la confirmación: preguntar "¿seguro?" para
  // después no dejar aceptar es una pregunta de mentira. El toast dice qué
  // falta hacer, que es lo único accionable acá.
  const racks = racksDe(almacen.id).length;
  if (racks > 0) {
    mostrarToast(
      `${almacen.name} todavía tiene ${racks} rack${racks === 1 ? '' : 's'}. Elimínalos primero: un almacén solo se borra vacío.`,
      'bad'
    );
    return;
  }

  document.getElementById('modalConfirmarTitulo').textContent = 'Eliminar almacén';
  document.getElementById('modalConfirmarMensaje').textContent =
    `¿Eliminar ${almacen.name}? Solo se puede si no tiene inventario ni historial; si lo tiene, la operación se rechaza y te dice qué estorba.`;

  const btnViejo = document.getElementById('btnAceptarConfirmar');
  const aceptar = btnViejo.cloneNode(true); // limpia listeners de una confirmación anterior
  aceptar.textContent = 'Eliminar';
  btnViejo.replaceWith(aceptar);

  aceptar.addEventListener('click', async () => {
    aceptar.disabled = true;
    aceptar.textContent = 'Eliminando…';
    try {
      const resultado = await InventarioAPI.eliminarAlmacen(almacen.code);

      // Lo que estuviera sin guardar de este almacén ya no tiene dónde ir.
      entradaModificada.delete(almacen.id);
      racksDe(almacen.id).forEach((r) => racksModificados.delete(r.id));
      deseleccionarRack();
      actualizarBarraEdicion();

      ocultarModal('modalConfirmar');
      await recargarLayout();
      actualizarPanelAlmacen();
      mostrarToast(resultado.mensaje ?? 'Almacén eliminado.', 'ok');
    } catch (err) {
      // Si tiene inventario o historial, el mensaje viene de la base con el
      // detalle exacto: se muestra tal cual.
      ocultarModal('modalConfirmar');
      mostrarToast(err.message ?? 'No se pudo eliminar el almacén.', 'bad');
    } finally {
      aceptar.disabled = false;
      aceptar.textContent = 'Eliminar';
    }
  }, { once: true });

  mostrarModal('modalConfirmar');
});

// =============================================================================
//  CONTENIDO DE UN RACK: EL FRENTE DE LA ESTANTERÍA
// =============================================================================
// El plano es la planta —la vista desde arriba—; esto es el alzado: el rack
// visto de frente, con los niveles apilados como en la realidad (el 1 abajo)
// y cada casillero con su ancho proporcional al real, de modo que uno de 15 cm
// de lo infantil se ve angosto al lado de uno de 78 cm de adulto.
const CELDA_MIN_PX = 38;

function abrirContenidoRack(rackId) {
  rackAbierto = rackId;
  renderContenidoRack();
  repintar();
}

function cerrarContenidoRack() {
  rackAbierto = null;
  document.getElementById('panelContenidoRack').hidden = true;
  document.querySelector('.mapa-cuerpo')?.classList.remove('con-panel');
  repintar();
}

// Cambiaron los datos (se ubicó, se liberó, se cambió de almacén): el panel
// abierto se redibuja, o se cierra si su rack ya no está a la vista.
function refrescarContenidoRack() {
  if (!rackAbierto) return;
  const rack = layoutRacks.find((r) => r.id === rackAbierto);
  const almacen = rack && layoutAlmacenes.find((a) => a.id === rack.warehouse_id);
  const filtro = document.getElementById('filtroMapaAlmacen').value;
  if (!rack || modoEdicion || (filtro && almacen?.code !== filtro)) {
    cerrarContenidoRack();
    return;
  }
  renderContenidoRack();
}

function renderContenidoRack() {
  const rack = layoutRacks.find((r) => r.id === rackAbierto);
  if (!rack) return;
  const almacen = layoutAlmacenes.find((a) => a.id === rack.warehouse_id);
  const filas = todoElMapa.filter((f) => f.almacen_code === almacen.code && f.rack === rack.code);
  const todos = casilleros(filas);
  const hay = todos.reduce((suma, c) => suma + cajasEn(c), 0);
  const caben = todos.reduce((suma, c) => suma + (c.capacity_units ?? 0), 0);
  const modelos = new Set(filas.filter((f) => f.product_id).map((f) => f.product_id)).size;

  document.getElementById('contenidoRackTitulo').textContent = `${almacen.code} · ${rack.code}`;
  document.getElementById('contenidoRackResumen').textContent =
    `${rack.grid_ancho} × ${rack.grid_alto} m · ${rack.niveles} niveles · ${todos.length} casilleros · ` +
    `${formatearNumero(hay)} de ${formatearNumero(caben)} cajas · ${modelos} modelo${modelos === 1 ? '' : 's'}`;

  document.getElementById('panelContenidoRack').hidden = false;
  document.querySelector('.mapa-cuerpo')?.classList.add('con-panel');

  const porNivel = new Map();
  for (const c of todos) {
    if (!porNivel.has(c.level)) porNivel.set(c.level, []);
    porNivel.get(c.level).push(c);
  }

  // Una sola escala para el rack entero: la que deja el casillero más angosto
  // en al menos CELDA_MIN_PX. Así todos los niveles miden lo mismo —como la
  // estantería real— y un nivel con muchos casilleros no se ve más largo.
  const cont = document.getElementById('contenidoRackFrente');
  const masCasilleros = Math.max(1, ...[...porNivel.values()].map((lista) => lista.length));
  const disponible = Math.max(200, cont.clientWidth - 70);
  const anchoFila = Math.max(disponible, CELDA_MIN_PX * masCasilleros);

  cont.innerHTML = '';
  const niveles = document.createElement('div');
  niveles.className = 'frente-niveles';
  niveles.style.width = `${Math.round(anchoFila) + 46}px`;

  for (let nivel = rack.niveles; nivel >= 1; nivel--) {
    const lista = (porNivel.get(nivel) ?? [])
      .sort((a, b) => a.posicion.localeCompare(b.posicion, undefined, { numeric: true }));

    const fila = document.createElement('div');
    fila.className = 'frente-nivel' + (esNivelInfantil(nivel) ? ' infantil' : '');

    const etiqueta = document.createElement('div');
    etiqueta.className = 'frente-nivel-etiqueta';
    const numero = document.createElement('span');
    numero.textContent = `n${nivel}`;
    const publico = document.createElement('span');
    publico.textContent = esNivelInfantil(nivel) ? 'niño' : 'adulto';
    etiqueta.append(numero, publico);

    const celdas = document.createElement('div');
    celdas.className = 'frente-celdas';
    if (lista.length === 0) {
      const vacio = document.createElement('span');
      vacio.className = 'frente-vacio';
      vacio.textContent = 'Sin casilleros en este nivel';
      celdas.appendChild(vacio);
    } else {
      const ancho = anchoFila / lista.length - 2;
      for (const c of lista) celdas.appendChild(celdaFrente(c, ancho));
    }

    fila.append(etiqueta, celdas);
    niveles.appendChild(fila);
  }
  cont.appendChild(niveles);
}

function celdaFrente(c, anchoPx) {
  const hay = cajasEn(c);
  const caben = c.capacity_units ?? 0;
  const celda = document.createElement('button');
  celda.type = 'button';
  celda.className = 'frente-celda';
  celda.style.width = `${Math.max(8, Math.floor(anchoPx))}px`;
  if (c.tallas.length) celda.classList.add(c.tallas[0].estado_ocupacion.toLowerCase());
  if (hay > caben) celda.classList.add('sobrecargado');

  const modelo = document.createElement('span');
  modelo.className = 'frente-celda-modelo';
  modelo.textContent = c.tallas.length ? (c.tallas[0].model_code ?? c.tallas[0].sku) : '';
  const tallas = document.createElement('span');
  tallas.className = 'frente-celda-tallas';
  // Con "T" delante: en un casillero de 15 cm el número solo no se distingue
  // de una cantidad. El detalle completo va en el title.
  tallas.textContent = c.tallas.map((t) => (t.talla ? `T${t.talla}` : '')).filter(Boolean).join(' ');
  const barra = document.createElement('span');
  barra.className = 'frente-barra';
  const relleno = document.createElement('span');
  relleno.style.width = `${caben ? Math.min(100, (hay / caben) * 100) : (hay ? 100 : 0)}%`;
  barra.appendChild(relleno);
  celda.append(modelo, tallas, barra);

  const detalle = c.tallas.length
    ? `${c.tallas[0].producto}: ${c.tallas.map((t) => `talla ${t.talla ?? '?'} · ${t.unidades} pares`).join(', ')}`
    : 'Libre';
  celda.title = `${c.posicion} — ${detalle} — ${hay} de ${caben} cajas`;
  celda.setAttribute('aria-label', celda.title);
  if (c.tallas.length) {
    celda.addEventListener('click', () => abrirCasillero(c));
  } else {
    celda.disabled = true;
  }
  return celda;
}

document.getElementById('btnCerrarContenidoRack').addEventListener('click', cerrarContenidoRack);
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape' || !rackAbierto) return;
  // Con un modal abierto encima, Escape es para el modal.
  if (document.querySelector('.modal-backdrop:not([hidden])')) return;
  cerrarContenidoRack();
});

normalizarCodigoAlEscribir('campoNuevoAlmacenCodigo');
normalizarCodigoAlEscribir('campoNuevoRackCodigo');
