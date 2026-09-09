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

// Una casilla por posición. Ocupadas/reservadas/en picking son <button> de
// verdad (clic o Enter libera); las libres son <button disabled> — se ven,
// se leen con el lector de pantalla, pero no entran al orden de tabulación
// de algo que no se puede accionar.
function tilePosicion(fila) {
  const libre = fila.estado_ocupacion === null;
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'mapa-tile';
  if (!libre) btn.classList.add(fila.estado_ocupacion.toLowerCase());
  if (fila.level === 1) btn.classList.add('infantil');

  const estadoTexto = libre
    ? 'Libre'
    : (ETIQUETA_OCUPACION[fila.estado_ocupacion]?.texto ?? fila.estado_ocupacion);
  const detalle = libre ? '' : ` — ${fila.sku} · ${fila.producto}${fila.talla ? ' talla ' + fila.talla : ''} (${fila.unidades} uds)`;
  btn.title = `${fila.rack} · ${fila.posicion} — nivel ${fila.level}${fila.level === 1 ? ' (infantil)' : ''} — ${estadoTexto}${detalle}`;
  btn.setAttribute('aria-label', btn.title + (libre ? '' : ' — clic para liberar'));

  if (libre) {
    btn.disabled = true;
  } else {
    btn.addEventListener('click', () => liberarDesdeElMapa(fila));
  }

  return btn;
}

// Agrupa por almacén y, dentro de cada uno, por rack — así cada tarjeta de
// rack dibuja sus posiciones juntas, como se verían físicamente en el piso.
function agruparParaMapa(filas) {
  const porAlmacen = new Map();
  for (const f of filas) {
    if (!porAlmacen.has(f.almacen)) porAlmacen.set(f.almacen, new Map());
    const porRack = porAlmacen.get(f.almacen);
    if (!porRack.has(f.rack)) porRack.set(f.rack, []);
    porRack.get(f.rack).push(f);
  }
  return porAlmacen;
}

function renderMapaVisual(filas) {
  const cont = document.getElementById('mapaVisual');
  cont.innerHTML = '';

  if (filas.length === 0) {
    cont.innerHTML = `<div class="estado-vacio"><p>Ninguna posición coincide</p><p>Prueba con otro almacén o quita el filtro.</p></div>`;
    return;
  }

  const agrupado = agruparParaMapa(filas);
  for (const [almacen, porRack] of agrupado) {
    const bloque = document.createElement('div');
    bloque.className = 'mapa-bloque-almacen';
    const titulo = document.createElement('h3');
    titulo.textContent = almacen;
    bloque.appendChild(titulo);

    const racksCont = document.createElement('div');
    racksCont.className = 'mapa-racks';

    for (const [rack, posiciones] of porRack) {
      const card = document.createElement('div');
      card.className = 'mapa-rack-card';
      card.innerHTML = `<div class="mapa-rack-titulo">${rack}</div>`;

      const tiles = document.createElement('div');
      tiles.className = 'mapa-tiles';
      posiciones
        .slice()
        .sort((a, b) => a.posicion.localeCompare(b.posicion))
        .forEach((f) => tiles.appendChild(tilePosicion(f)));

      card.appendChild(tiles);
      racksCont.appendChild(card);
    }

    bloque.appendChild(racksCont);
    cont.appendChild(bloque);
  }
}

function aplicarFiltroMapa() {
  const almacen = document.getElementById('filtroMapaAlmacen').value;
  const soloLibres = document.getElementById('filtroMapaSoloLibres').checked;

  const filtradas = todoElMapa.filter((f) => {
    if (almacen && f.almacen_code !== almacen) return false;
    if (soloLibres && f.estado_ocupacion !== null) return false;
    return true;
  });

  document.getElementById('contadorMapa').textContent = `${filtradas.length} de ${todoElMapa.length} posiciones`;
  renderMapaVisual(filtradas);
}

function inicializarMapa(mapa) {
  todoElMapa = mapa;
  aplicarFiltroMapa();
}

document.getElementById('filtroMapaAlmacen').addEventListener('change', aplicarFiltroMapa);
document.getElementById('filtroMapaSoloLibres').addEventListener('change', aplicarFiltroMapa);

async function liberarDesdeElMapa(fila) {
  try {
    await InventarioAPI.liberarPosicion(fila.assignment_id);
    mostrarToast(`Posición ${fila.rack} · ${fila.posicion} liberada.`, 'ok');
    await recargarArticulos();
  } catch (err) {
    mostrarToast(err.message ?? 'No se pudo liberar la posición.', 'bad');
  }
}

// --- Modal "Ubicar artículo" ---------------------------------------------

let articuloAUbicar = null;

function posicionesLibresDe(almacenCode) {
  return todoElMapa.filter((f) => f.almacen_code === almacenCode && f.estado_ocupacion === null);
}

function poblarSelectPosiciones(almacenCode) {
  const select = document.getElementById('campoUbicPosicion');
  select.innerHTML = '';
  const libres = posicionesLibresDe(almacenCode);

  if (libres.length === 0) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = 'No hay posiciones libres en este almacén';
    select.appendChild(opt);
    return;
  }

  for (const pos of libres) {
    const opt = document.createElement('option');
    opt.value = pos.position_id;
    opt.textContent = `${pos.rack} · ${pos.posicion} (nivel ${pos.level}${pos.level === 1 ? ' · infantil' : ''})`;
    select.appendChild(opt);
  }
}

function abrirModalUbicar(articulo) {
  articuloAUbicar = articulo;
  document.getElementById('formUbicacion').reset();
  document.getElementById('modalUbicacionError').hidden = true;
  document.getElementById('modalUbicacionTitulo').textContent = `Ubicar — ${articulo.sku}`;
  document.getElementById('campoUbicCantidad').value = '';

  const asignacionActual = todoElMapa.find((f) => f.item_id === articulo.id);
  const cajaActual = document.getElementById('grupoUbicacionActual');
  if (asignacionActual) {
    cajaActual.hidden = false;
    document.getElementById('ubicacionActualTexto').textContent =
      `${asignacionActual.almacen} · ${asignacionActual.rack} · ${asignacionActual.posicion} (${ETIQUETA_OCUPACION[asignacionActual.estado_ocupacion]?.texto ?? asignacionActual.estado_ocupacion}, ${asignacionActual.unidades} uds)`;
  } else {
    cajaActual.hidden = true;
  }

  const selectAlmacen = document.getElementById('campoUbicAlmacen');
  selectAlmacen.value = asignacionActual?.almacen_code ?? 'ALM-A';
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

document.getElementById('btnLiberarUbicacionActual').addEventListener('click', async () => {
  const asignacionActual = todoElMapa.find((f) => f.item_id === articuloAUbicar?.id);
  if (!asignacionActual) return;
  const boton = document.getElementById('btnLiberarUbicacionActual');
  boton.disabled = true;
  try {
    await InventarioAPI.liberarPosicion(asignacionActual.assignment_id);
    mostrarToast('Posición liberada.', 'ok');
    cerrarModalUbicacion();
    await recargarArticulos();
  } catch (err) {
    const errorEl = document.getElementById('modalUbicacionError');
    errorEl.textContent = err.message ?? 'No se pudo liberar.';
    errorEl.hidden = false;
    errorEl.focus();
  } finally {
    boton.disabled = false;
  }
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
    if (!positionId) throw new Error('Elige una posición libre.');

    const cantidad = parseInt(document.getElementById('campoUbicCantidad').value, 10);
    if (!cantidad || cantidad <= 0) throw new Error('La cantidad debe ser mayor que cero.');

    await InventarioAPI.asignarPosicion({
      positionId,
      itemId: articuloAUbicar.id,
      quantity: cantidad,
      status: document.getElementById('campoUbicEstado').value,
      notes: document.getElementById('campoUbicNotas').value.trim() || null,
    });

    cerrarModalUbicacion();
    mostrarToast('Posición asignada.', 'ok');
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
