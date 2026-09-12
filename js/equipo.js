// Sección "Equipo": quién trabaja en el almacén y qué puede hacer cada uno.
// Solo la ve un JEFE — no por discreción, sino porque es el único que puede
// cambiar algo aquí: la política p_profiles_update y el trigger
// trg_profiles_no_autoascenso rechazan a cualquier otro. Ocultarla evita
// ofrecer controles que el servidor va a rechazar.
//
// Lo que se muestra de cada rol no está escrito a mano: es el reparto real que
// aplican las funciones de la base con fn_exigir_rol().

const ROLES = {
  JEFE: {
    etiqueta: 'Jefe de almacén',
    plural: 'jefes de almacén',
    resumen: 'Todo lo anterior, más revertir movimientos ya ejecutados y administrar al equipo.',
    puede: ['Revertir un movimiento ejecutado', 'Asignar roles y dar de baja a alguien',
            'Eliminar artículos sin pedir permiso a nadie'],
  },
  SUPERVISOR: {
    etiqueta: 'Supervisor',
    plural: 'supervisores',
    resumen: 'Autoriza lo que piden los operarios y mantiene el catálogo y el almacén.',
    puede: ['Aprobar y rechazar movimientos', 'Crear artículos, marcas, categorías y proveedores',
            'Crear y medir almacenes y racks'],
  },
  OPERARIO: {
    etiqueta: 'Operario',
    plural: 'operarios',
    resumen: 'Trabaja la mercadería: pide movimientos y los ejecuta cuando están autorizados.',
    puede: ['Crear movimientos (quedan pendientes)', 'Ejecutar los ya aprobados',
            'Ubicar, reubicar y liberar casilleros'],
  },
  AUDITOR: {
    etiqueta: 'Auditor',
    plural: 'auditores',
    resumen: 'Solo lectura: ve todo y no puede cambiar nada.',
    puede: ['Consultar stock, movimientos y kardex'],
  },
};

let miembros = [];

// La etiqueta de color del rol. Misma clase en la tabla y en la chuleta de
// abajo, para que el color signifique lo mismo en los dos sitios.
function chipRol(rol) {
  const span = document.createElement('span');
  span.className = `rol-chip rol-${rol.toLowerCase()}`;
  span.textContent = ROLES[rol]?.etiqueta ?? rol;
  return span;
}

// Un jefe no puede quitarse el rol a sí mismo: si fuera el único, el almacén
// se quedaría sin nadie que pueda aprobar ni administrar, y hay que entrar por
// el SQL Editor a arreglarlo.
function esElUltimoJefe(miembro) {
  const jefesActivos = miembros.filter((m) => m.role === 'JEFE' && m.is_active);
  return miembro.role === 'JEFE' && jefesActivos.length <= 1;
}

// La fila de una persona, con lo que se le puede cambiar. Dos casos se tratan
// aparte: uno mismo (no puede darse de baja) y el último jefe activo (ver
// esElUltimoJefe).
function filaMiembro(m, yoId) {
  const tr = document.createElement('tr');
  const soyYo = m.id === yoId;

  // Una celda de la fila. Acepta texto o un nodo ya montado: los controles
  // (el selector de rol, el tope) se construyen aparte y se meten aquí.
  const celda = (contenido, clase) => {
    const td = document.createElement('td');
    if (clase) td.className = clase;
    if (typeof contenido === 'string') td.textContent = contenido;
    else td.appendChild(contenido);
    return td;
  };

  const nombre = document.createElement('div');
  nombre.textContent = m.full_name;
  if (soyYo) {
    const tu = document.createElement('span');
    tu.className = 'pill';
    tu.textContent = 'tú';
    nombre.append(' ', tu);
  }
  tr.appendChild(celda(nombre, 'celda-texto'));
  tr.appendChild(celda(m.email ?? '—', 'celda-texto'));

  // El rol: un select, salvo en la fila del único jefe que queda.
  if (esElUltimoJefe(m)) {
    const fijo = chipRol(m.role);
    fijo.title = 'Es el único jefe activo: para cambiarlo, nombra antes a otro.';
    tr.appendChild(celda(fijo));
  } else {
    const select = document.createElement('select');
    select.className = 'filtro-select';
    for (const [valor, info] of Object.entries(ROLES)) {
      select.add(new Option(info.etiqueta, valor, false, valor === m.role));
    }
    select.addEventListener('change', () => guardar(m, { role: select.value }, select));
    tr.appendChild(celda(select));
  }

  // El tope por movimiento: vacío = sin límite.
  const tope = document.createElement('input');
  tope.type = 'number';
  tope.min = '1';
  tope.max = '99999';
  tope.className = 'input-tope';
  tope.value = m.max_movement_qty ?? '';
  tope.placeholder = 'sin tope';
  // El tope lo comprueba fn_aprobar_movimiento, así que solo pinta algo en
  // quien aprueba. A un operario o a un auditor no les afecta: se deja a la
  // vista pero apagado, para que no parezca que hace algo que no hace.
  const aprueba = m.role === 'SUPERVISOR' || m.role === 'JEFE';
  tope.disabled = !aprueba;
  tope.title = aprueba
    ? 'Cantidad máxima que puede autorizar de una vez. Por encima, escala a un jefe. Vacío = sin límite.'
    : `Un ${ROLES[m.role].etiqueta.toLowerCase()} no aprueba movimientos, así que este tope no le aplica.`;
  if (!aprueba) tope.placeholder = 'no aplica';
  tope.addEventListener('change', () => {
    const valor = tope.value.trim() === '' ? null : parseInt(tope.value, 10);
    if (valor !== null && (!Number.isFinite(valor) || valor < 1)) {
      mostrarToast('El tope tiene que ser un número mayor que cero, o quedar vacío.', 'error');
      tope.value = m.max_movement_qty ?? '';
      return;
    }
    guardar(m, { max_movement_qty: valor }, tope);
  });
  tr.appendChild(celda(tope));

  const estado = document.createElement('span');
  estado.className = `pill ${m.is_active ? 'ok' : 'off'}`;
  estado.textContent = m.is_active ? 'Activo' : 'Dado de baja';
  tr.appendChild(celda(estado));

  const acciones = document.createElement('td');
  acciones.className = 'acciones';
  if (!soyYo && !esElUltimoJefe(m)) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'btn-accion';
    btn.textContent = m.is_active ? 'Dar de baja' : 'Reactivar';
    btn.addEventListener('click', () => guardar(m, { is_active: !m.is_active }, btn));
    acciones.appendChild(btn);
  }
  tr.appendChild(acciones);

  return tr;
}

// Dar de baja no borra: fn_rol_actual() solo devuelve el rol de un perfil
// activo, así que un inactivo deja de pasar RLS y no puede hacer nada, pero su
// firma sigue en los movimientos que aprobó.
async function guardar(miembro, cambios, control) {
  control.disabled = true;
  try {
    await AuthAPI.actualizarMiembro(miembro.id, cambios);
    mostrarToast(`${miembro.full_name}: cambio guardado.`, 'ok');
    await recargarEquipo();
  } catch (err) {
    mostrarToast(traducirError(err, 'No se pudo guardar el cambio.'), 'error');
    await recargarEquipo();
  } finally {
    control.disabled = false;
  }
}

// La tabla completa, ordenada por jerarquía y luego por nombre, con el resumen
// de cuánta gente hay de cada rol.
function renderEquipo(yoId) {
  const cuerpo = document.getElementById('tablaEquipoBody');
  cuerpo.innerHTML = '';

  if (miembros.length === 0) {
    const tr = document.createElement('tr');
    const td = document.createElement('td');
    td.colSpan = 6;
    td.className = 'skeleton';
    td.textContent = 'No hay nadie más registrado todavía.';
    tr.appendChild(td);
    cuerpo.appendChild(tr);
    return;
  }

  const orden = ['JEFE', 'SUPERVISOR', 'OPERARIO', 'AUDITOR'];
  const ordenados = [...miembros].sort((a, b) =>
    orden.indexOf(a.role) - orden.indexOf(b.role) || a.full_name.localeCompare(b.full_name));

  for (const m of ordenados) cuerpo.appendChild(filaMiembro(m, yoId));

  const activos = miembros.filter((m) => m.is_active).length;
  const porRol = orden
    .map((r) => [r, miembros.filter((m) => m.role === r && m.is_active).length])
    .filter(([, n]) => n > 0)
    .map(([r, n]) => `${n} ${n === 1 ? ROLES[r].etiqueta.toLowerCase() : ROLES[r].plural}`)
    .join(' · ');
  document.getElementById('contadorEquipo').textContent =
    `${activos} activo${activos === 1 ? '' : 's'} de ${miembros.length}${porRol ? ' — ' + porRol : ''}`;
}

// La chuleta de qué puede hacer cada rol. Se dibuja desde la misma constante
// que documenta el reparto, para que no se quede vieja en el HTML.
function renderPermisos() {
  const cont = document.getElementById('permisosPorRol');
  cont.innerHTML = '';
  for (const [rol, info] of Object.entries(ROLES)) {
    const bloque = document.createElement('div');
    bloque.className = 'permiso-rol';
    bloque.appendChild(chipRol(rol));

    const resumen = document.createElement('p');
    resumen.className = 'permiso-resumen';
    resumen.textContent = info.resumen;
    bloque.appendChild(resumen);

    const ul = document.createElement('ul');
    for (const linea of info.puede) {
      const li = document.createElement('li');
      li.textContent = linea;
      ul.appendChild(li);
    }
    bloque.appendChild(ul);
    cont.appendChild(bloque);
  }
}

// Relee el equipo desde la base. Se llama después de cada cambio en vez de
// tocar la fila a mano: así lo que se ve es lo que la base aceptó, que no
// siempre es lo que se pidió.
async function recargarEquipo() {
  const perfil = await AuthAPI.obtenerPerfilActual();
  if (perfil?.role !== 'JEFE') return;
  miembros = await AuthAPI.listarMiembros();
  renderEquipo(perfil.id);
}

// La pestaña solo existe para el jefe. No es la barrera de seguridad —esa es
// RLS— sino no enseñar controles que el servidor va a rechazar.
function prepararEquipo(perfil) {
  const esJefe = perfil?.role === 'JEFE';
  document.getElementById('tabEquipo').hidden = !esJefe;
  if (!esJefe) return;
  renderPermisos();
  recargarEquipo();
}
