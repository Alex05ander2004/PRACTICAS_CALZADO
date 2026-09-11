// Modal de "nuevo movimiento" y las acciones de workflow (aprobar, rechazar,
// ejecutar, revertir) que dashboard.js llama desde los botones de cada fila
// de la tabla de movimientos. Fase 8.

// --- Nuevo movimiento ----------------------------------------------------

function abrirModalMovimiento() {
  document.getElementById('formMovimiento').reset();
  document.getElementById('modalMovimientoError').hidden = true;
  document.getElementById('grupoMovDireccion').hidden = true;

  const select = document.getElementById('campoMovArticulo');
  select.innerHTML = '';
  for (const art of todosLosArticulos) {
    const opt = document.createElement('option');
    opt.value = art.id;
    opt.textContent = `${art.sku} — ${art.product?.name ?? ''}`;
    select.appendChild(opt);
  }

  poblarCasillerosMovimiento();
  mostrarModal('modalMovimiento');
}

function cerrarModalMovimiento() {
  ocultarModal('modalMovimiento');
}

document.getElementById('btnNuevoMovimiento').addEventListener('click', abrirModalMovimiento);
document.getElementById('btnCerrarModalMovimiento').addEventListener('click', cerrarModalMovimiento);
document.getElementById('btnCancelarMovimiento').addEventListener('click', cerrarModalMovimiento);
document.getElementById('modalMovimiento').addEventListener('click', (e) => {
  if (e.target.id === 'modalMovimiento') cerrarModalMovimiento();
});

// El selector "sumar/restar" solo importa para AJUSTE (ver comentario en
// MovimientosAPI.crear). Para ENTRADA/SALIDA el signo lo decide el tipo.
document.querySelectorAll('input[name="movTipo"]').forEach((radio) => {
  radio.addEventListener('change', () => {
    const tipo = document.querySelector('input[name="movTipo"]:checked').value;
    document.getElementById('grupoMovDireccion').hidden = tipo !== 'AJUSTE';
    poblarCasillerosMovimiento();
  });
});

document.getElementById('campoMovArticulo').addEventListener('change', poblarCasillerosMovimiento);

// El casillero dice de qué estante sale una SALIDA o a cuál entra una ENTRADA.
// Sin él, ejecutar un movimiento cambiaba el stock pero no los estantes, y el
// mapa terminaba mostrando cajas que ya se habían ido (migración 20).
function poblarCasillerosMovimiento() {
  const select = document.getElementById('campoMovCasillero');
  const ayuda = document.getElementById('ayudaMovCasillero');
  select.innerHTML = '';
  ayuda.textContent = '';

  const articulo = todosLosArticulos.find((a) => a.id === document.getElementById('campoMovArticulo').value);
  if (!articulo) return;

  const tipo = document.querySelector('input[name="movTipo"]:checked')?.value ?? 'ENTRADA';
  const inv = articulo.inventory?.[0];
  const almacenCode = layoutAlmacenes.find((a) => a.id === inv?.warehouse_id)?.code;
  // Lo RESERVADA es sitio apartado para algo que no llegó: no son cajas que se
  // puedan sacar.
  const donde = todoElMapa.filter((f) => f.item_id === articulo.id && f.assignment_id && f.estado_ocupacion !== 'RESERVADA');
  const enEstantes = donde.reduce((suma, f) => suma + (f.unidades ?? 0), 0);
  const sinUbicar = Math.max(0, (inv?.quantity ?? 0) - enEstantes);

  if (tipo === 'ENTRADA') {
    select.add(new Option('Recepción — ubicar después', ''));
    for (const c of casillerosDisponiblesPara(almacenCode, articulo)) {
      select.add(new Option(`${c.rack} · ${c.posicion} (nivel ${c.level}) — caben ${c.libre} más`, c.position_id));
    }
    ayuda.textContent = 'Con un casillero elegido, al ejecutar la entrada las cajas quedan ubicadas ahí.';
    return;
  }

  for (const f of donde) {
    select.add(new Option(`${f.rack} · ${f.posicion} — hay ${f.unidades}`, f.position_id));
  }
  if (sinUbicar > 0 || donde.length === 0) {
    select.add(new Option(`Recepción, sin ubicar — hay ${sinUbicar}`, ''));
  }
  ayuda.textContent = tipo === 'SALIDA'
    ? 'Al ejecutar la salida, las cajas se descuentan de este casillero.'
    : 'Un ajuste con casillero corrige también lo que hay en ese estante.';
}

document.getElementById('formMovimiento').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  const boton = document.getElementById('btnGuardarMovimiento');
  const errorEl = document.getElementById('modalMovimientoError');
  const textoOriginal = boton.textContent;
  errorEl.hidden = true;
  boton.disabled = true;
  boton.textContent = 'Creando…';

  try {
    const itemId = document.getElementById('campoMovArticulo').value;
    const articulo = todosLosArticulos.find((a) => a.id === itemId);
    const inventoryId = articulo?.inventory?.[0]?.id;
    if (!inventoryId) {
      throw new Error('Este artículo no tiene registro de inventario. Créalo primero editándolo.');
    }

    const cantidad = parseInt(document.getElementById('campoMovCantidad').value, 10);
    if (!cantidad || cantidad <= 0) throw new Error('La cantidad debe ser mayor que cero.');

    const tipo = document.querySelector('input[name="movTipo"]:checked').value;
    const direction = tipo === 'AJUSTE' ? parseInt(document.getElementById('campoMovDireccion').value, 10) : undefined;

    await MovimientosAPI.crear({
      itemId,
      inventoryId,
      positionId: document.getElementById('campoMovCasillero').value || null,
      movementType: tipo,
      quantity: cantidad,
      direction,
      reason: document.getElementById('campoMovMotivo').value.trim() || null,
      notes: document.getElementById('campoMovNotas').value.trim() || null,
    });

    cerrarModalMovimiento();
    mostrarToast('Movimiento creado como Pendiente.', 'ok');
    await recargarArticulos();
  } catch (err) {
    errorEl.textContent = err.message ?? 'No se pudo crear el movimiento.';
    errorEl.hidden = false;
    errorEl.focus();
  } finally {
    boton.disabled = false;
    boton.textContent = textoOriginal;
  }
});

// --- Motivo reutilizable: rechazar (opcional) y revertir (obligatorio) ---

function abrirModalMotivo({ titulo, mensaje, requerido, textoBoton, onConfirmar }) {
  document.getElementById('modalMotivoTitulo').textContent = titulo;
  document.getElementById('modalMotivoMensaje').textContent = mensaje;
  document.getElementById('campoMotivoLabel').textContent = requerido ? 'Motivo (obligatorio)' : 'Motivo (opcional)';
  document.getElementById('campoMotivoTexto').value = '';
  document.getElementById('modalMotivoError').hidden = true;
  document.getElementById('btnAceptarMotivo').textContent = textoBoton;
  mostrarModal('modalMotivo');

  // El formulario se clona para limpiar el listener de submit de la vez
  // anterior (cada llamada trae su propio onConfirmar) — mismo patrón que
  // confirmarEliminarArticulo usa con el botón de aceptar.
  const formViejo = document.getElementById('formMotivo');
  const form = formViejo.cloneNode(true);
  formViejo.replaceWith(form);
  document.getElementById('btnCancelarMotivo').addEventListener('click', () => ocultarModal('modalMotivo'));

  form.addEventListener('submit', async (evento) => {
    evento.preventDefault();
    const errorEl = document.getElementById('modalMotivoError');
    const motivo = document.getElementById('campoMotivoTexto').value.trim();

    if (requerido && !motivo) {
      errorEl.textContent = 'El motivo es obligatorio.';
      errorEl.hidden = false;
      errorEl.focus();
      return;
    }

    const boton = document.getElementById('btnAceptarMotivo');
    boton.disabled = true;
    boton.textContent = 'Guardando…';
    try {
      await onConfirmar(motivo || null);
      ocultarModal('modalMotivo');
    } catch (err) {
      errorEl.textContent = err.message ?? 'No se pudo completar la acción.';
      errorEl.hidden = false;
      errorEl.focus();
    } finally {
      boton.disabled = false;
      boton.textContent = textoBoton;
    }
  });
}

// --- Acciones de workflow, llamadas desde dashboard.js -------------------

async function aprobarMovimientoUI(mov) {
  try {
    await MovimientosAPI.aprobar(mov.id);
    mostrarToast('Movimiento aprobado. Queda pendiente de ejecución física.', 'ok');
    await recargarArticulos();
  } catch (err) {
    mostrarToast(err.message ?? 'No se pudo aprobar.', 'bad');
  }
}

async function ejecutarMovimientoUI(mov) {
  try {
    await MovimientosAPI.ejecutar(mov.id);
    mostrarToast('Movimiento ejecutado: el stock ya se actualizó.', 'ok');
    await recargarArticulos();
  } catch (err) {
    mostrarToast(err.message ?? 'No se pudo ejecutar.', 'bad');
  }
}

function solicitarMotivoYRechazar(mov) {
  abrirModalMotivo({
    titulo: 'Rechazar movimiento',
    mensaje: `¿Rechazar el movimiento de "${mov.producto}" (${mov.sku})? El stock no se modifica.`,
    requerido: false,
    textoBoton: 'Rechazar',
    onConfirmar: async (motivo) => {
      await MovimientosAPI.rechazar(mov.id, motivo);
      mostrarToast('Movimiento rechazado.', 'ok');
      await recargarArticulos();
    },
  });
}

function solicitarMotivoYRevertir(mov) {
  abrirModalMotivo({
    titulo: 'Revertir movimiento',
    mensaje: `¿Revertir el movimiento ya ejecutado de "${mov.producto}" (${mov.sku})? Se genera un contra-asiento — el original no se borra ni se edita. Solo un jefe puede hacerlo.`,
    requerido: true,
    textoBoton: 'Revertir',
    onConfirmar: async (motivo) => {
      await MovimientosAPI.revertir(mov.id, motivo);
      mostrarToast('Movimiento revertido.', 'ok');
      await recargarArticulos();
    },
  });
}
