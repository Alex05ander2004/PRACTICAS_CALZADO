// Espejo de fn_niveles_infantiles() (migración 15). El corte real lo aplica la
// base con su trigger; esto solo decide cómo se rotula el mapa, así que si
// algún día cambia allá, este número tiene que seguirla.
const NIVELES_INFANTILES = 2;
const esNivelInfantil = (nivel) => nivel <= NIVELES_INFANTILES;

// Mapa del almacén (lectura + filtro) y el modal "Ubicar artículo" que asigna
// o libera una posición. Fase 9: cierra el hueco de "necesidades adicionales"
// del CASO.txt que quedó solo en el esquema — mapa de racks/posiciones,
// evitar doble ocupación, reservar espacio para INBOUND, preparar OUTBOUND.
//
// A propósito NO filtra de antemano qué posiciones "deberían" aceptar un
// artículo según su público (niño/adulto): se muestran todas las libres del
// almacén elegido, y si se intenta una que no corresponde, el trigger
// trg_assign_publico_nivel de la base la rechaza y el error se ve tal cual en
// el modal. Es la forma honesta de demostrar que la regla la aplica la base
// de datos, no una lista precocinada en el cliente.

let todoElMapa = [];

const ETIQUETA_OCUPACION = {
  OCUPADA: { texto: 'Ocupada', clase: 'ok' },
  RESERVADA: { texto: 'Reservada', clase: 'warn' },
  EN_PICKING: { texto: 'En picking', clase: 'info' },
};

// Desde la migración 20 un casillero guarda un modelo con varias tallas, y
// v_mapa_almacen devuelve una fila por talla ubicada (una sola, vacía, si el
// casillero está libre). Lo que se dibuja y se cuenta es el casillero.
function casilleros(filas) {
  const porId = new Map();
  for (const f of filas) {
    if (!porId.has(f.position_id)) porId.set(f.position_id, { ...f, tallas: [] });
    if (f.assignment_id) porId.get(f.position_id).tallas.push(f);
  }
  return [...porId.values()];
}

const cajasEn = (casillero) => casillero.tallas.reduce((suma, t) => suma + (t.unidades ?? 0), 0);

// Lo que se lee antes de mirar el plano: cuántos racks y casilleros hay,
// cuántas cajas de cuántas caben, cuántos modelos, y lo que falta revisar.
function renderResumenAlmacen(almacenCode) {
  const cont = document.getElementById('resumenAlmacen');
  const filas = todoElMapa.filter((f) => !almacenCode || f.almacen_code === almacenCode);
  const lista = casilleros(filas);
  const racks = new Set(filas.map((f) => `${f.almacen_code}/${f.rack}`)).size;
  const hay = lista.reduce((suma, c) => suma + cajasEn(c), 0);
  const caben = lista.reduce((suma, c) => suma + (c.capacity_units ?? 0), 0);
  const ocupados = lista.filter((c) => c.tallas.length > 0).length;
  const modelos = new Set(filas.filter((f) => f.product_id).map((f) => f.product_id)).size;
  const pendientes = revision.filter((r) => !almacenCode || r.almacen_code === almacenCode).length;

  cont.innerHTML = '';
  cont.append(
    datoResumen(racks, racks === 1 ? 'rack' : 'racks'),
    datoResumen(`${ocupados}/${lista.length}`, 'casilleros ocupados'),
    datoResumen(`${formatearNumero(hay)} de ${formatearNumero(caben)}`, `cajas (${caben ? Math.round((hay / caben) * 100) : 0}%)`),
    datoResumen(modelos, modelos === 1 ? 'modelo' : 'modelos'),
  );
  if (pendientes > 0) cont.appendChild(datoResumen(pendientes, 'por revisar', true));
}

function datoResumen(valor, texto, alerta = false) {
  const el = document.createElement('span');
  el.className = 'resumen-dato' + (alerta ? ' alerta' : '');
  const fuerte = document.createElement('strong');
  fuerte.textContent = valor;
  el.append(fuerte, ` ${texto}`);
  return el;
}

function aplicarFiltroMapa() {
  const almacen = document.getElementById('filtroMapaAlmacen').value;
  renderResumenAlmacen(almacen);
  renderRevision();
  renderPlano(almacen, todoElMapa);
  poblarSelectsRuta(almacen);
  refrescarContenidoRack();
}

function inicializarMapa(mapa) {
  todoElMapa = mapa;
  aplicarFiltroMapa();
  // No se espera: la revisión es informativa y el mapa no debe quedarse en
  // blanco mientras llega.
  refrescarRevision();
}

document.getElementById('filtroMapaAlmacen').addEventListener('change', aplicarFiltroMapa);

async function liberarDesdeElMapa(fila) {
  try {
    await InventarioAPI.liberarPosicion(fila.assignment_id);
    mostrarToast(`${fila.sku} fuera de ${fila.rack} · ${fila.posicion}.`, 'ok');
    await recargarArticulos();
  } catch (err) {
    mostrarToast(err.message ?? 'No se pudo liberar.', 'bad');
  }
}

function lineaConBoton(texto, textoBoton, onClick) {
  const fila = document.createElement('div');
  fila.className = 'linea-ubicacion-actual';
  const etiqueta = document.createElement('span');
  etiqueta.textContent = texto;
  const boton = document.createElement('button');
  boton.type = 'button';
  boton.className = 'btn-accion';
  boton.textContent = textoBoton;
  boton.addEventListener('click', () => onClick(boton));
  fila.append(etiqueta, boton);
  return fila;
}

// Un clic muestra las tallas del casillero y liberar es un botón aparte. Antes,
// con una sola talla, el clic liberaba de inmediato: mirar un casillero bastaba
// para sacar cajas del sistema sin registrar ninguna salida.
function abrirCasillero(c) {
  document.getElementById('modalCasilleroTitulo').textContent = `${c.almacen_code} · ${c.rack} · ${c.posicion}`;
  const lista = document.getElementById('listaCasillero');
  lista.innerHTML = '';
  for (const t of c.tallas) {
    lista.appendChild(lineaConBoton(`${t.sku} · talla ${t.talla ?? '?'} — ${t.unidades} cajas`, 'Liberar', async () => {
      ocultarModal('modalCasillero');
      await liberarDesdeElMapa(t);
    }));
  }
  mostrarModal('modalCasillero');
}

document.getElementById('btnCerrarModalCasillero').addEventListener('click', () => ocultarModal('modalCasillero'));
document.getElementById('modalCasillero').addEventListener('click', (e) => {
  if (e.target.id === 'modalCasillero') ocultarModal('modalCasillero');
});

// --- Modal "Ubicar artículo" ---------------------------------------------

let articuloAUbicar = null;

// Casilleros donde este artículo puede ir: vacíos, o que ya guardan su mismo
// modelo y todavía tienen sitio (un casillero admite un solo modelo desde la
// migración 20). Primero los que ya tienen el modelo, para juntar las tallas.
// A propósito NO se filtra por nivel: si se elige uno que no corresponde al
// público del artículo, lo rechaza el trigger de la base — ver arriba.
function casillerosDisponiblesPara(almacenCode, articulo) {
  const modelo = articulo?.product?.id;
  return casilleros(todoElMapa.filter((f) => f.almacen_code === almacenCode))
    .filter((c) => c.tallas.every((t) => t.product_id === modelo))
    .map((c) => ({ ...c, libre: (c.capacity_units ?? 0) - cajasEn(c) }))
    .filter((c) => c.libre > 0)
    .sort((a, b) => (b.tallas.length > 0) - (a.tallas.length > 0) || a.posicion.localeCompare(b.posicion));
}

function poblarSelectPosiciones(almacenCode) {
  const select = document.getElementById('campoUbicPosicion');
  select.innerHTML = '';
  const disponibles = casillerosDisponiblesPara(almacenCode, articuloAUbicar);

  if (disponibles.length === 0) {
    select.add(new Option('No hay casilleros con sitio para este modelo en este almacén', ''));
    return;
  }

  for (const c of disponibles) {
    const yaEsta = c.tallas.length > 0 ? ' · ya guarda este modelo' : '';
    select.add(new Option(
      `${c.rack} · ${c.posicion} (nivel ${c.level}${esNivelInfantil(c.level) ? ' · infantil' : ''}) — caben ${c.libre} más${yaEsta}`,
      c.position_id
    ));
  }
}

function abrirModalUbicar(articulo) {
  articuloAUbicar = articulo;
  document.getElementById('formUbicacion').reset();
  document.getElementById('modalUbicacionError').hidden = true;
  document.getElementById('modalUbicacionTitulo').textContent = `Ubicar — ${articulo.sku}`;
  document.getElementById('campoUbicCantidad').value = '';

  // Puede estar repartido en varios casilleros (una reubicación que no cupo en
  // uno solo): se listan todos, cada uno con lo suyo, y se libera de a uno.
  const actuales = todoElMapa.filter((f) => f.item_id === articulo.id && f.assignment_id);
  const lista = document.getElementById('listaUbicacionActual');
  lista.innerHTML = '';
  document.getElementById('grupoUbicacionActual').hidden = actuales.length === 0;
  for (const a of actuales) {
    const estado = ETIQUETA_OCUPACION[a.estado_ocupacion]?.texto ?? a.estado_ocupacion;
    lista.appendChild(lineaConBoton(`${a.almacen} · ${a.rack} · ${a.posicion} — ${a.unidades} cajas (${estado})`, 'Liberar', async (boton) => {
      boton.disabled = true;
      try {
        await InventarioAPI.liberarPosicion(a.assignment_id);
        mostrarToast(`${a.sku} fuera de ${a.rack} · ${a.posicion}.`, 'ok');
        cerrarModalUbicacion();
        await recargarArticulos();
      } catch (err) {
        const errorEl = document.getElementById('modalUbicacionError');
        errorEl.textContent = err.message ?? 'No se pudo liberar.';
        errorEl.hidden = false;
        errorEl.focus();
        boton.disabled = false;
      }
    }));
  }

  // El select ya viene con los almacenes reales y el primero elegido; solo se
  // pisa esa elección si el artículo ya está ubicado en alguno.
  const selectAlmacen = document.getElementById('campoUbicAlmacen');
  if (actuales[0]?.almacen_code) selectAlmacen.value = actuales[0].almacen_code;
  poblarSelectPosiciones(selectAlmacen.value);

  mostrarModal('modalUbicacion');
}

document.getElementById('campoUbicAlmacen').addEventListener('change', (e) => {
  poblarSelectPosiciones(e.target.value);
});

function cerrarModalUbicacion() {
  ocultarModal('modalUbicacion');
  articuloAUbicar = null;
}

document.getElementById('btnCerrarModalUbicacion').addEventListener('click', cerrarModalUbicacion);
document.getElementById('btnCancelarUbicacion').addEventListener('click', cerrarModalUbicacion);
document.getElementById('modalUbicacion').addEventListener('click', (e) => {
  if (e.target.id === 'modalUbicacion') cerrarModalUbicacion();
});

document.getElementById('formUbicacion').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  const boton = document.getElementById('btnGuardarUbicacion');
  const errorEl = document.getElementById('modalUbicacionError');
  const textoOriginal = boton.textContent;
  errorEl.hidden = true;
  boton.disabled = true;
  boton.textContent = 'Asignando…';

  try {
    const positionId = document.getElementById('campoUbicPosicion').value;
    if (!positionId) throw new Error('Elige un casillero.');

    const cantidad = parseInt(document.getElementById('campoUbicCantidad').value, 10);
    if (!cantidad || cantidad <= 0) throw new Error('La cantidad debe ser mayor que cero.');

    // Por RPC y no con un INSERT: si el casillero ya guarda esta misma talla se
    // suma a esa fila, y la base se niega a ubicar más pares de los que hay en
    // stock.
    await InventarioAPI.ubicarEnCasillero({
      positionId,
      itemId: articuloAUbicar.id,
      quantity: cantidad,
      status: document.getElementById('campoUbicEstado').value,
      notes: document.getElementById('campoUbicNotas').value.trim() || null,
    });

    cerrarModalUbicacion();
    mostrarToast('Ubicado.', 'ok');
    await recargarArticulos();
  } catch (err) {
    // Si el trigger de capacidad, doble ocupación o público/nivel rechaza la
    // asignación, el mensaje llega tal cual desde la base — no se reescribe.
    errorEl.textContent = err.message ?? 'No se pudo asignar la posición.';
    errorEl.hidden = false;
    errorEl.focus();
  } finally {
    boton.disabled = false;
    boton.textContent = textoOriginal;
  }
});

// =============================================================================
//  REVISIÓN DE UBICACIONES
// =============================================================================
// Todo lo que está fuera de lugar, agrupado por tipo (v_revision_ubicaciones,
// migración 21). Cada corrección registra en el sistema un movimiento físico:
// se aprieta después de mover las cajas, no en lugar de moverlas.
const TIPOS_REVISION = {
  NIVEL: {
    titulo: 'Nivel equivocado',
    ayuda: 'Calzado en un nivel que no es el de su público. Se sube o se baja al que corresponde, en el mismo rack si hay sitio.',
    accion: 'Reubicar', todos: 'Reubicar todos',
  },
  SOBRECARGA: {
    titulo: 'Casilleros sobrecargados',
    ayuda: 'Más cajas de las que caben. El sobrante se reparte en casilleros con sitio para ese modelo.',
    accion: 'Repartir', todos: 'Repartir todos',
  },
  RECEPCION: {
    titulo: 'En recepción, sin ubicar',
    ayuda: 'Pares en stock que no están en ningún estante. Se ubican juntando las tallas de cada modelo.',
    accion: 'Ubicar', todos: 'Ubicar todos',
  },
  FANTASMA: {
    titulo: 'Cajas fantasma',
    ayuda: 'Más pares en los estantes que en el stock. Solo un conteo sabe cuál de los dos miente: elige en qué confiar.',
    accion: null, todos: null,
  },
};

let revision = [];

async function refrescarRevision() {
  try {
    revision = await InventarioAPI.listarRevision();
  } catch (err) {
    // La vista llega con la migración 21: sin ella la revisión no aparece, en
    // vez de romper el mapa entero.
    revision = [];
  }
  renderRevision();
  renderResumenAlmacen(document.getElementById('filtroMapaAlmacen').value);
}

function renderRevision() {
  const panel = document.getElementById('panelRevision');
  const cont = document.getElementById('listaRevision');
  const almacen = document.getElementById('filtroMapaAlmacen').value;
  const filas = revision.filter((r) => !almacen || r.almacen_code === almacen);

  panel.hidden = filas.length === 0;
  document.getElementById('revisionTitulo').textContent =
    `Revisión de ubicaciones · ${filas.length} pendiente${filas.length === 1 ? '' : 's'}`;
  cont.innerHTML = '';

  for (const [tipo, info] of Object.entries(TIPOS_REVISION)) {
    const delTipo = filas.filter((r) => r.tipo === tipo);
    if (delTipo.length === 0) continue;

    const grupo = document.createElement('section');
    grupo.className = 'revision-grupo';

    const cabecera = document.createElement('div');
    cabecera.className = 'revision-grupo-cabecera';
    const textos = document.createElement('div');
    const titulo = document.createElement('h4');
    titulo.className = 'revision-grupo-titulo';
    titulo.textContent = `${info.titulo} · ${delTipo.length}`;
    const ayuda = document.createElement('p');
    ayuda.className = 'revision-grupo-ayuda';
    ayuda.textContent = info.ayuda;
    textos.append(titulo, ayuda);
    cabecera.appendChild(textos);

    if (info.todos && delTipo.length > 1) {
      const todos = document.createElement('button');
      todos.type = 'button';
      todos.className = 'btn-secundario btn-chico';
      todos.textContent = info.todos;
      todos.addEventListener('click', () => resolverTodos(tipo, todos));
      cabecera.appendChild(todos);
    }
    grupo.appendChild(cabecera);

    const lista = document.createElement('div');
    lista.className = 'reubicaciones-lista';
    for (const r of delTipo) lista.appendChild(filaRevision(r, info));
    grupo.appendChild(lista);
    cont.appendChild(grupo);
  }
}

function filaRevision(r, info) {
  const fila = document.createElement('div');
  fila.className = 'reubicacion-fila';

  const texto = document.createElement('span');
  texto.className = 'reubicacion-detalle';
  const donde = [r.almacen_code, r.rack, r.casillero].filter(Boolean).join(' · ');
  const que = r.sku ? `${r.sku} ${r.producto ?? ''}`.trim() : '';
  texto.textContent = [donde, que, r.detalle].filter(Boolean).join(' — ');
  fila.appendChild(texto);

  const acciones = document.createElement('span');
  acciones.className = 'revision-acciones';
  if (r.tipo === 'FANTASMA') {
    acciones.append(
      botonRevision('Liberar sobrante', 'Confía en el stock: saca de los estantes lo que sobra',
        () => InventarioAPI.resolverFantasma(r.item_id, r.warehouse_id, 'STOCK')),
      botonRevision('Ajustar stock', 'Confía en los estantes: crea un ajuste pendiente de aprobación',
        () => InventarioAPI.resolverFantasma(r.item_id, r.warehouse_id, 'ESTANTES')),
    );
  } else {
    const accion = {
      NIVEL: () => InventarioAPI.reubicarAsignacion(r.assignment_id),
      SOBRECARGA: () => InventarioAPI.repartirSobrecarga(r.position_id),
      RECEPCION: () => InventarioAPI.ubicarRecepcion(r.inventory_id),
    }[r.tipo];
    acciones.appendChild(botonRevision(info.accion, null, accion));
  }
  fila.appendChild(acciones);
  return fila;
}

function botonRevision(texto, titulo, accion) {
  const boton = document.createElement('button');
  boton.type = 'button';
  boton.className = 'btn-secundario btn-chico';
  boton.textContent = texto;
  if (titulo) boton.title = titulo;
  boton.addEventListener('click', async () => {
    boton.disabled = true;
    boton.textContent = '…';
    try {
      const res = await accion();
      mostrarToast(res?.mensaje ?? 'Listo.', 'ok');
      // Recarga todo y no solo el mapa: "Ajustar stock" crea un movimiento.
      await recargarArticulos();
    } catch (err) {
      mostrarToast(err.message ?? 'No se pudo corregir.', 'bad');
      boton.disabled = false;
      boton.textContent = texto;
    }
  });
  return boton;
}

async function resolverTodos(tipo, boton) {
  boton.disabled = true;
  boton.textContent = 'Corrigiendo…';
  try {
    const res = await InventarioAPI.resolverRevision(tipo);
    const fallas = res?.detalle ?? [];
    if (fallas.length === 0) {
      mostrarToast(`${res.resueltos} corregidos.`, 'ok');
    } else {
      // Los que no se pudieron no se pierden: siguen en la revisión con su motivo.
      mostrarToast(`${res.resueltos} corregidos; ${fallas.length} sin resolver: ${fallas[0].motivo}`, 'bad');
    }
    await recargarArticulos();
  } catch (err) {
    mostrarToast(err.message ?? 'No se pudo corregir.', 'bad');
    boton.disabled = false;
  }
}
