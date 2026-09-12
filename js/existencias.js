// Existencias por ubicación: el mismo inventario que el plano, pero en lista.
//
// El plano responde "cómo está distribuido el almacén"; esto responde "qué
// guarda este rack" y "dónde está este modelo", dos preguntas que en el plano
// obligan a abrir rack por rack. La diferencia se nota cuando un modelo quedó
// repartido: en el plano son tres celdas que hay que ir juntando a ojo, acá es
// una línea con sus tallas sumadas.
//
// Se arma con todoElMapa, que el mapa ya trae cargado: ni consulta ni vista
// nuevas.

let filtroExistencias = '';   // en minúsculas, para comparar
let textoBuscado = '';        // tal como se escribió, para mostrarlo

const tomar = (mapa, clave, crear) => {
  if (!mapa.has(clave)) mapa.set(clave, crear());
  return mapa.get(clave);
};

function nombreDeAlmacen(code) {
  return layoutAlmacenes.find((a) => a.code === code)?.name ?? code;
}

// almacén -> rack -> modelo, sumando las tallas de un mismo modelo aunque estén
// en casilleros distintos.
function agruparExistencias(filas) {
  const almacenes = new Map();

  for (const f of filas) {
    if (!f.estado_ocupacion) continue; // los casilleros libres no son existencias

    const alm = tomar(almacenes, f.almacen_code, () => ({
      code: f.almacen_code, nombre: nombreDeAlmacen(f.almacen_code),
      racks: new Map(), modelos: new Set(), pares: 0,
    }));
    const rack = tomar(alm.racks, f.rack, () => ({
      code: f.rack, modelos: new Map(), casilleros: new Set(), pares: 0,
    }));
    const clave = f.product_id ?? f.model_code ?? f.producto;
    const modelo = tomar(rack.modelos, clave, () => ({
      codigo: f.model_code ?? f.sku, nombre: f.producto,
      tallas: new Map(), casilleros: new Set(), niveles: new Set(), skus: new Set(), pares: 0,
    }));

    const unidades = f.unidades ?? 0;
    const talla = f.talla ?? '—';
    modelo.tallas.set(talla, (modelo.tallas.get(talla) ?? 0) + unidades);
    modelo.casilleros.add(f.posicion);
    modelo.skus.add(f.sku);
    if (f.level != null) modelo.niveles.add(f.level);
    modelo.pares += unidades;

    rack.casilleros.add(f.posicion);
    rack.pares += unidades;
    alm.modelos.add(clave);
    alm.pares += unidades;
  }

  return almacenes;
}

// Un modelo entra en la búsqueda por su código, su nombre, cualquiera de sus
// SKU, una talla exacta o un casillero: "574", "new balance", "ZAP-005-40",
// "40" y "A-07-12" tienen que encontrarlo.
function coincideExistencia(modelo) {
  if (!filtroExistencias) return true;
  const t = filtroExistencias;
  return (modelo.codigo ?? '').toLowerCase().includes(t)
    || (modelo.nombre ?? '').toLowerCase().includes(t)
    || [...modelo.skus].some((sku) => (sku ?? '').toLowerCase().includes(t))
    || [...modelo.tallas.keys()].some((talla) => String(talla).toLowerCase() === t)
    || [...modelo.casilleros].some((c) => (c ?? '').toLowerCase().includes(t));
}

function dato(texto, clase = 'exis-datos') {
  const el = document.createElement('span');
  el.className = clase;
  el.textContent = texto;
  return el;
}

function filaModelo(modelo) {
  const fila = document.createElement('div');
  fila.className = 'exis-modelo';

  fila.append(
    dato(modelo.codigo ?? '—', 'exis-modelo-codigo'),
    dato(modelo.nombre ?? '—', 'exis-modelo-nombre'),
  );

  const tallas = document.createElement('span');
  tallas.className = 'exis-tallas';
  for (const [talla, pares] of [...modelo.tallas].sort((a, b) => String(a[0]).localeCompare(String(b[0]), undefined, { numeric: true }))) {
    // "talla 40 · 26" y no "40×26": el segundo número necesita que el primero
    // se lea como talla, o parecen dos medidas.
    const etiqueta = dato(`talla ${talla} · ${pares}`, 'exis-talla');
    etiqueta.title = `${pares} pares de la talla ${talla}`;
    tallas.appendChild(etiqueta);
  }
  fila.appendChild(tallas);

  fila.appendChild(dato(`${formatearNumero(modelo.pares)} pares`, 'exis-pares'));

  const niveles = [...modelo.niveles].sort((a, b) => a - b).map((n) => `n${n}`).join(' ');
  const donde = [...modelo.casilleros].sort((a, b) => a.localeCompare(b, undefined, { numeric: true })).join(', ');
  fila.appendChild(dato([niveles, donde].filter(Boolean).join(' · '), 'exis-donde'));

  return fila;
}

function renderExistencias() {
  const cont = document.getElementById('listaExistencias');
  if (!cont) return;

  const almacenes = agruparExistencias(todoElMapa ?? []);
  cont.innerHTML = '';

  // Modelos distintos, no líneas: un modelo repartido en dos racks son dos
  // líneas pero un solo modelo.
  const modelos = new Set();
  let racks = 0;
  let pares = 0;

  // Se recorren los almacenes que existen, no solo los que tienen algo: uno
  // vacío tiene que decir que está vacío, no desaparecer y dejar la duda.
  const ordenados = [...layoutAlmacenes].sort((a, b) => a.code.localeCompare(b.code));
  for (const { code } of ordenados) {
    const alm = almacenes.get(code) ?? { code, nombre: nombreDeAlmacen(code), racks: new Map(), modelos: new Set(), pares: 0 };
    const conStock = [...alm.racks.values()]
      .map((rack) => ({ rack, lista: [...rack.modelos.values()].filter(coincideExistencia).sort((a, b) => b.pares - a.pares) }))
      .filter(({ lista }) => lista.length > 0)
      .sort((a, b) => a.rack.code.localeCompare(b.rack.code, undefined, { numeric: true }));
    if (conStock.length === 0) {
      // Buscando, un almacén sin coincidencias solo estorba.
      if (filtroExistencias) continue;
      const vacio = document.createElement('p');
      vacio.className = 'exis-almacen-vacio';
      vacio.append(dato(alm.code, 'exis-codigo'), dato(alm.nombre, 'exis-nombre'), dato('sin nada ubicado'));
      cont.appendChild(vacio);
      continue;
    }

    const bloque = document.createElement('details');
    bloque.className = 'exis-almacen';
    bloque.open = true;

    const cabecera = document.createElement('summary');
    cabecera.append(
      dato(alm.code, 'exis-codigo'),
      dato(alm.nombre, 'exis-nombre'),
      dato(`${conStock.length} rack${conStock.length === 1 ? '' : 's'} · ${alm.modelos.size} modelos · ${formatearNumero(alm.pares)} pares`),
    );
    bloque.appendChild(cabecera);

    for (const { rack, lista } of conStock) {
      const bloqueRack = document.createElement('details');
      bloqueRack.className = 'exis-rack';
      // Buscando, los racks se abren solos: lo que se busca es el resultado, no
      // el rack donde está.
      bloqueRack.open = Boolean(filtroExistencias);

      const cabeceraRack = document.createElement('summary');
      const paresRack = lista.reduce((suma, m) => suma + m.pares, 0);
      cabeceraRack.append(
        dato(rack.code, 'exis-codigo'),
        dato(`${lista.length} modelo${lista.length === 1 ? '' : 's'} · ${formatearNumero(paresRack)} pares · ${rack.casilleros.size} casilleros`),
      );
      bloqueRack.appendChild(cabeceraRack);

      const filas = document.createElement('div');
      filas.className = 'exis-modelos';
      for (const modelo of lista) filas.appendChild(filaModelo(modelo));
      bloqueRack.appendChild(filas);

      bloque.appendChild(bloqueRack);
      racks += 1;
      for (const m of lista) modelos.add(m.codigo ?? m.nombre);
      pares += paresRack;
    }

    cont.appendChild(bloque);
  }

  const contador = document.getElementById('contadorExistencias');
  if (cont.children.length === 0) {
    cont.innerHTML = '';
    const vacio = document.createElement('p');
    vacio.className = 'exis-vacio';
    vacio.textContent = filtroExistencias
      ? `Nada coincide con "${textoBuscado}".`
      : 'Todavía no hay nada ubicado en los estantes.';
    cont.appendChild(vacio);
  }
  contador.textContent = filtroExistencias
    ? `${modelos.size} modelo${modelos.size === 1 ? '' : 's'} en ${racks} rack${racks === 1 ? '' : 's'} · ${formatearNumero(pares)} pares`
    : `${racks} racks con existencias · ${modelos.size} modelos ubicados · ${formatearNumero(pares)} pares`;
}

document.getElementById('buscarExistencias').addEventListener('input', (e) => {
  textoBuscado = e.target.value.trim();
  filtroExistencias = textoBuscado.toLowerCase();
  renderExistencias();
});

document.getElementById('btnLimpiarExistencias').addEventListener('click', () => {
  document.getElementById('buscarExistencias').value = '';
  textoBuscado = '';
  filtroExistencias = '';
  renderExistencias();
});
