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
let ambitoExistencias = 'todo';

const tomar = (mapa, clave, crear) => {
  if (!mapa.has(clave)) mapa.set(clave, crear());
  return mapa.get(clave);
};

// El nombre bonito del almacén. Cae al código si el layout todavía no cargó:
// mejor "ALM-A" que un hueco en blanco.
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
    // Una misma talla puede estar en dos casilleros con estados distintos, así
    // que se guarda el conjunto: si alguno está comprometido, la talla lo está
    // en parte, y eso es lo que hay que poder ver.
    const previo = modelo.tallas.get(talla) ?? { pares: 0, estados: new Set() };
    previo.pares += unidades;
    previo.estados.add(f.estado_ocupacion);
    modelo.tallas.set(talla, previo);
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

// La talla se compara exacta y el resto por contenido. Eso solo no alcanza:
// "40" es la talla 40, pero también está dentro del modelo ZAP-040 y de todo
// SKU terminado en -40, así que sin ámbito los resultados se mezclan.
function porModelo(modelo, t) {
  const codigo = (modelo.codigo ?? '').toLowerCase();
  // t.startsWith(codigo) deja pegar un SKU entero ("zap-005-40") y encontrar su
  // modelo, sin que un número suelto haga coincidir a todos por su SKU.
  return codigo.includes(t)
    || (modelo.nombre ?? '').toLowerCase().includes(t)
    || (codigo !== '' && t.startsWith(codigo));
}

// Coincidencia EXACTA de talla, no "contiene": buscar 40 no debe traer la 40.5.
const porTalla = (modelo, t) => [...modelo.tallas.keys()].some((talla) => String(talla).toLowerCase() === t);

// Filtro por estado del casillero. COMPROMETIDO junta los dos que no son
// stock disponible sin más, que es como se suelen mirar.
let estadoExistencias = '';

function coincideEstado(modelo) {
  if (!estadoExistencias) return true;
  const estados = new Set();
  for (const dato of modelo.tallas.values()) for (const e of dato.estados) estados.add(e);
  if (estadoExistencias === 'COMPROMETIDO') {
    return estados.has('RESERVADA') || estados.has('EN_PICKING');
  }
  return estados.has(estadoExistencias);
}
// El casillero sí se busca por fragmento: "A-07" trae todo ese rack.
const porCasillero = (modelo, t) => [...modelo.casilleros].some((c) => (c ?? '').toLowerCase().includes(t));

// "Dónde" son tres niveles del mismo eje: almacén, rack y casillero. El código
// de casillero (A-07-52) no contiene la palabra "RACK", así que buscar el rack
// tiene que mirar su código aparte.
function coincideUbicacion(rack, alm) {
  if (!filtroExistencias) return false;
  if (ambitoExistencias !== 'todo' && ambitoExistencias !== 'ubicacion') return false;
  const t = filtroExistencias;
  return (rack.code ?? '').toLowerCase().includes(t)
    || (alm.code ?? '').toLowerCase().includes(t)
    || (alm.nombre ?? '').toLowerCase().includes(t);
}

// Decide si un modelo pasa el buscador, según el ámbito elegido. Sin ámbito,
// "40" mezclaba la talla 40 con el modelo ZAP-040 y con todo SKU acabado en -40.
function coincideExistencia(modelo) {
  if (!filtroExistencias) return true;
  const t = filtroExistencias;
  if (ambitoExistencias === 'modelo') return porModelo(modelo, t);
  if (ambitoExistencias === 'talla') return porTalla(modelo, t);
  if (ambitoExistencias === 'ubicacion') return porCasillero(modelo, t);
  return porModelo(modelo, t) || porTalla(modelo, t) || porCasillero(modelo, t)
    || [...modelo.skus].some((sku) => (sku ?? '').toLowerCase().includes(t));
}

// Un trozo de texto de la fila, con su clase. Se usa para todas las columnas.
function dato(texto, clase = 'exis-datos') {
  const el = document.createElement('span');
  el.className = clase;
  el.textContent = texto;
  return el;
}

// La línea de un modelo dentro de un rack: código, nombre, sus tallas con las
// cantidades, el total y dónde está. Las tallas comprometidas salen marcadas
// con el mismo color que el plano.
function filaModelo(modelo) {
  const fila = document.createElement('div');
  fila.className = 'exis-modelo';

  fila.append(
    dato(modelo.codigo ?? '—', 'exis-modelo-codigo'),
    dato(modelo.nombre ?? '—', 'exis-modelo-nombre'),
  );

  const tallas = document.createElement('span');
  tallas.className = 'exis-tallas';
  for (const [talla, info] of [...modelo.tallas].sort((a, b) => String(a[0]).localeCompare(String(b[0]), undefined, { numeric: true }))) {
    const pares = info.pares;
    // "talla 40 · 26" y no "40×26": el segundo número necesita que el primero
    // se lea como talla, o parecen dos medidas.
    const etiqueta = dato(`talla ${talla} · ${pares}`, 'exis-talla');
    etiqueta.title = `${pares} pares de la talla ${talla}`;
    // El estado del casillero, con el mismo color que el plano.
    const comprometido = info.estados.has('EN_PICKING') ? 'en_picking'
                       : info.estados.has('RESERVADA')  ? 'reservada' : '';
    if (comprometido) {
      etiqueta.classList.add(comprometido);
      etiqueta.title = comprometido === 'en_picking'
        ? 'Comprometido: hay una salida esperando sobre este casillero'
        : 'Reservado: sitio apartado para mercadería que todavía no llegó';
    }
    tallas.appendChild(etiqueta);
  }
  fila.appendChild(tallas);

  fila.appendChild(dato(`${formatearNumero(modelo.pares)} pares`, 'exis-pares'));

  const niveles = [...modelo.niveles].sort((a, b) => a - b).map((n) => `n${n}`).join(' ');
  const donde = [...modelo.casilleros].sort((a, b) => a.localeCompare(b, undefined, { numeric: true })).join(', ');
  fila.appendChild(dato([niveles, donde].filter(Boolean).join(' · '), 'exis-donde'));

  return fila;
}

// Dibuja el árbol entero almacén → rack → modelo aplicando los filtros. Un
// almacén sin nada también aparece: que esté vacío es información, y no verlo
// haría pensar que no existe.
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
      // Si lo que coincide es el rack o el almacén, se muestra entero; si
      // coincide un casillero suelto, solo lo que guarda ese casillero.
      .map((rack) => {
        const entero = coincideUbicacion(rack, alm);
        const lista = [...rack.modelos.values()]
          .filter((m) => (entero || coincideExistencia(m)) && coincideEstado(m))
          .sort((a, b) => b.pares - a.pares);
        return { rack, lista };
      })
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
      ? `Nada coincide con "${textoBuscado}"${AMBITOS[ambitoExistencias] ?? ''}.`
      : 'Todavía no hay nada ubicado en los estantes.';
    cont.appendChild(vacio);
  }
  contador.textContent = filtroExistencias
    ? `${modelos.size} modelo${modelos.size === 1 ? '' : 's'} en ${racks} rack${racks === 1 ? '' : 's'} · ${formatearNumero(pares)} pares`
    : `${racks} racks con existencias · ${modelos.size} modelos ubicados · ${formatearNumero(pares)} pares`;
}

// Qué dice el mensaje de vacío y qué se espera escribir en cada ámbito.
const AMBITOS = { todo: '', modelo: ' en modelos y SKU', talla: ' en las tallas', ubicacion: ' en almacenes, racks y casilleros' };
const PISTAS = {
  todo: 'Buscar modelo, SKU, talla, rack o casillero…',
  modelo: 'Modelo o SKU: 574, pegasus, ZAP-005-40…',
  talla: 'Talla exacta: 40, 41.5…',
  ubicacion: 'Almacén, rack o casillero: BOD-B, RACK-07, A-07-52…',
};

document.getElementById('ambitoExistencias').addEventListener('change', (e) => {
  ambitoExistencias = e.target.value;
  document.getElementById('buscarExistencias').placeholder = PISTAS[ambitoExistencias];
  renderExistencias();
});

document.getElementById('estadoExistencias').addEventListener('change', (e) => {
  estadoExistencias = e.target.value;
  renderExistencias();
});

document.getElementById('buscarExistencias').addEventListener('input', (e) => {
  textoBuscado = e.target.value.trim();
  filtroExistencias = textoBuscado.toLowerCase();
  renderExistencias();
});

document.getElementById('btnLimpiarExistencias').addEventListener('click', () => {
  document.getElementById('buscarExistencias').value = '';
  document.getElementById('estadoExistencias').value = '';
  textoBuscado = '';
  filtroExistencias = '';
  estadoExistencias = '';
  renderExistencias();
});
