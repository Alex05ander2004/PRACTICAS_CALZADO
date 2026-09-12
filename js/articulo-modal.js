// Modal de crear/editar artículo, confirmación de eliminación y toasts.
// Fase 6. Depende de CatalogoAPI / InventarioAPI (js/api/) y de
// recargarArticulos() (dashboard.js), pero dashboard.js no depende de nada de
// este archivo salvo llamar a abrirModalEditar/confirmarEliminarArticulo
// desde los botones de cada fila.

let catalogosCache = null;

// Valor de la opción "+ Nuevo proveedor…". No es un id, así que no puede
// chocar con uno real.
const NUEVO_PROVEEDOR = '__NUEVO__';
let articuloEnEdicion = null; // null = creando; objeto de CatalogoAPI.listarArticulos() = editando

// Un campo numérico vacío es NULL, no 0: "sin peso declarado" y "pesa cero" no
// son lo mismo, y la base distingue los dos.
function parseFloatOrNull(valor) {
  const n = parseFloat(valor);
  return Number.isFinite(n) ? n : null;
}

// Marcas, categorías, proveedores y productos, una sola vez por apertura del
// modal. La caché se invalida (catalogosCache = null) cuando se crea algo que
// tendría que aparecer en esas listas.
async function cargarCatalogosSiHaceFalta() {
  if (catalogosCache) return catalogosCache;
  const [marcas, categorias, proveedores, productos, codigosUsados] = await Promise.all([
    CatalogoAPI.listarMarcas(),
    CatalogoAPI.listarCategorias(),
    CatalogoAPI.listarProveedores(),
    CatalogoAPI.listarProductos(),
    CatalogoAPI.codigosDeModeloUsados(),
  ]);
  catalogosCache = { marcas, categorias, proveedores, productos, codigosUsados };
  return catalogosCache;
}

// Llena un <select> con id/nombre. Los productos se muestran como
// "ZAP-001 — Nike Pegasus" porque el código es lo que se busca a ojo.
function poblarSelectSimple(id, items, { placeholder } = {}) {
  const select = document.getElementById(id);
  select.innerHTML = '';
  if (placeholder) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = placeholder;
    select.appendChild(opt);
  }
  for (const item of items) {
    const opt = document.createElement('option');
    opt.value = item.id;
    opt.textContent = item.model_code ? `${item.model_code} — ${item.name}` : item.name;
    select.appendChild(opt);
  }
}

// El proveedor sale de la lista, o se da de alta en el momento. La opción va
// al final: es la excepción, no lo que se elige a diario.
function poblarProveedores(proveedores) {
  poblarSelectSimple('campoProveedor', proveedores, { placeholder: 'Sin proveedor' });
  const select = document.getElementById('campoProveedor');
  const opt = document.createElement('option');
  opt.value = NUEVO_PROVEEDOR;
  opt.textContent = '+ Nuevo proveedor…';
  select.appendChild(opt);
}

// --- Mostrar/ocultar bloques según el modo ---------------------------------

// Los datos del modelo (código, marca, nombre, categoría, proveedor, público)
// no se esconden cuando se agrega una talla a un producto que ya existe: se
// muestran cargados y bloqueados. Esconderlos dejaba la duda de a qué modelo
// se le estaba agregando la talla.
const CAMPOS_DEL_MODELO = ['campoModelCode', 'campoMarca', 'campoNombre',
                           'campoCategoria', 'campoProveedor', 'campoDescripcion'];

// Al agregarle una talla a un modelo que ya existe, sus datos se ven pero no se
// tocan: cambiarlos aquí afectaría a todas las demás tallas sin avisar.
function bloquearCamposDelModelo(bloquear) {
  for (const id of CAMPOS_DEL_MODELO) document.getElementById(id).disabled = bloquear;
}

// Enseña u oculta los campos que definen el modelo.
function mostrarBloqueDefinicionProducto(mostrar) {
  document.getElementById('bloqueModeloMarca').hidden = !mostrar;
  document.getElementById('grupoNombre').hidden = !mostrar;
  document.getElementById('bloqueCategoriaProveedor').hidden = !mostrar;
  document.getElementById('grupoDescripcion').hidden = !mostrar;
}

// El primer ZAP libre. Se busca el primer hueco y no el siguiente al último:
// si alguna vez se borra un modelo del medio, su número vuelve a estar
// disponible y no tiene sentido saltárselo. Queda editable: es una propuesta,
// no una imposición.
function siguienteCodigoDeModelo() {
  const usados = new Set(
    (catalogosCache?.codigosUsados ?? [])
      .filter((c) => /^ZAP-[0-9]+$/.test(c))
      .map((c) => parseInt(c.slice(4), 10)));

  let n = 1;
  while (usados.has(n)) n += 1;
  return `ZAP-${String(n).padStart(3, '0')}`;
}

// Rango de tallas y caja estándar de cada público. La caja es la misma que usa
// el cálculo de capacidad (fn_medidas_caja), en centímetros.
const PUBLICOS = {
  NINO:   { etiqueta: 'niño',   min: 20, max: 34, largo: 22, ancho: 15, alto: 9,  peso: 0.6 },
  ADULTO: { etiqueta: 'adulto', min: 35, max: 48, largo: 35, ancho: 25, alto: 13, peso: 0.9 },
};

// El SKU de los 80 artículos que hay es el código de modelo más la talla, así
// que se arma solo en vez de dejar que se escriba distinto.
function derivarSku() {
  const talla = document.getElementById('campoTalla').value.trim();
  const modo = document.querySelector('input[name="modoProducto"]:checked')?.value ?? 'EXISTENTE';
  let modelo = document.getElementById('campoModelCode').value.trim();

  if (!articuloEnEdicion && modo === 'EXISTENTE') {
    const id = document.getElementById('campoProducto').value;
    modelo = catalogosCache?.productos.find((p) => p.id === id)?.model_code ?? '';
  }
  // La media talla se escribe 31.5, pero el SKU no admite el punto
  // (inventory_items exige '^[A-Z0-9]+(-[A-Z0-9]+)+$'), así que va con guion:
  // ZAP-059-31-5.
  document.getElementById('campoSku').value =
    modelo && talla ? `${modelo}-${talla.replace('.', '-')}` : '';
  avisarSiLaTallaYaExiste();
}

// Repetir una talla que el modelo ya tiene es el error fácil de cometer, y la
// base lo rechaza con el nombre de un índice. Se avisa en cuanto se escribe,
// junto al campo, en vez de esperar a que falle el guardado.
function tallaRepetida() {
  const lista = typeof todosLosArticulos !== 'undefined' ? todosLosArticulos : [];
  const sku = document.getElementById('campoSku').value;
  if (!sku) return null;
  return lista.find((a) => a.sku === sku && a.id !== articuloEnEdicion?.id) ?? null;
}

// Vender por debajo del costo casi siempre es un dedazo (un 9 por un 90), así
// que se avisa al escribirlo y no al guardar. Costo igual a precio sí pasa:
// margen cero es raro, pero no es un error.
function avisarSiElCostoSupera() {
  const costo = parseFloatOrNull(document.getElementById('campoCosto').value);
  const precio = parseFloatOrNull(document.getElementById('campoPrecio').value);
  const mal = costo != null && precio != null && costo > precio;
  const ayuda = document.getElementById('ayudaPrecio');
  ayuda.textContent = mal ? 'El precio no puede ser menor que el costo.' : '';
  ayuda.classList.toggle('campo-ayuda-error', mal);
  return mal;
}

// Repetir una talla que el modelo ya tiene es el error fácil de cometer. Se
// avisa junto al SKU en cuanto se escribe, en vez de dejar que reviente contra
// el índice al guardar.
function avisarSiLaTallaYaExiste() {
  const repetida = tallaRepetida();
  const ayuda = document.getElementById('ayudaSku');
  ayuda.textContent = repetida
    ? `Ese modelo ya tiene la talla ${repetida.size_label} (${repetida.sku}).`
    : 'Se arma solo con el modelo y la talla.';
  ayuda.classList.toggle('campo-ayuda-error', Boolean(repetida));
}

// Al cambiar de público cambian el rango de tallas y la caja. Las medidas solo
// se pisan si están vacías o si son las del otro público: si alguien puso una
// medida a mano, se respeta.
function aplicarPublico() {
  const publico = PUBLICOS[document.getElementById('campoPublico').value] ?? PUBLICOS.ADULTO;
  const otro = publico === PUBLICOS.NINO ? PUBLICOS.ADULTO : PUBLICOS.NINO;

  const talla = document.getElementById('campoTalla');
  talla.min = publico.min;
  talla.max = publico.max;
  talla.title = `Talla de ${publico.etiqueta}: entre ${publico.min} y ${publico.max}`;
  document.getElementById('ayudaPublico').textContent =
    `Tallas de ${publico.min} a ${publico.max}. Caja de ${publico.largo}×${publico.ancho}×${publico.alto} cm.`;

  for (const [id, valor, delOtro] of [
    ['campoLargo', publico.largo, otro.largo],
    ['campoAncho', publico.ancho, otro.ancho],
    ['campoAlto', publico.alto, otro.alto],
    ['campoPeso', publico.peso, otro.peso],
  ]) {
    const campo = document.getElementById(id);
    if (campo.value === '' || Number(campo.value) === delOtro) campo.value = valor;
  }
}

// Agregar una talla a un modelo que ya existe: se copian sus datos para verlos.
function precargarDesdeProducto() {
  const id = document.getElementById('campoProducto').value;
  const producto = catalogosCache?.productos.find((p) => p.id === id);
  if (!producto) return;

  document.getElementById('campoModelCode').value = producto.model_code ?? '';
  document.getElementById('campoNombre').value = producto.name ?? '';
  document.getElementById('campoDescripcion').value = producto.description ?? '';
  document.getElementById('campoMarca').value = producto.brand_id ?? producto.brand?.id ?? '';
  document.getElementById('campoCategoria').value = producto.category_id ?? producto.category?.id ?? '';
  // Proveedor y público: los del modelo son el punto de partida, pero la
  // talla nueva puede tener otros (otro proveedor para el mismo par, o una
  // talla de niño de un modelo que hasta ahora era solo de adulto).
  document.getElementById('campoProveedor').value = producto.supplier_id ?? producto.supplier?.id ?? '';
  document.getElementById('campoPublico').value = producto.audience === 'NINO' ? 'NINO' : 'ADULTO';

  aplicarPublico();
  derivarSku();
}

// Cambia el formulario entre "producto existente" y "producto nuevo". Los
// campos del modelo se ven en los dos casos —esconderlos dejaba la duda de a
// qué modelo se le está agregando la talla—, pero solo se editan en el nuevo.
function actualizarVisibilidadPorModo() {
  if (articuloEnEdicion) return; // al editar, el modo no aplica: siempre se ve todo

  const modo = document.querySelector('input[name="modoProducto"]:checked')?.value ?? 'EXISTENTE';
  const esNuevo = modo === 'NUEVO';
  document.getElementById('campoProductoExistente').hidden = esNuevo;
  mostrarBloqueDefinicionProducto(true);
  bloquearCamposDelModelo(!esNuevo);

  if (esNuevo) {
    for (const id of CAMPOS_DEL_MODELO) {
      const campo = document.getElementById(id);
      if (campo.tagName === 'INPUT' || campo.tagName === 'TEXTAREA') campo.value = '';
    }
    document.getElementById('campoModelCode').value = siguienteCodigoDeModelo();
    document.getElementById('campoPublico').value = 'ADULTO';
    aplicarPublico();
    derivarSku();
  } else {
    precargarDesdeProducto();
  }

  // El proveedor solo se elige (o se da de alta) cuando el modelo es nuevo:
  // al agregarle una talla a uno que ya existe se hereda el suyo.
  document.getElementById('ayudaProveedor').textContent = esNuevo
    ? 'Elige uno de la lista o da de alta uno nuevo.'
    : 'Es el del modelo: la talla se le compra a quien se le compra el modelo.';
  actualizarProveedorNuevo();
}

document.querySelectorAll('input[name="modoProducto"]').forEach((radio) => {
  radio.addEventListener('change', actualizarVisibilidadPorModo);
});

// --- Abrir / cerrar ----------------------------------------------------

// Cuenta cuántos modales están abiertos a la vez: con dos modales posibles
// (artículo + confirmar eliminar pueden solaparse), el scroll del body solo
// debe volver cuando se cierra el ÚLTIMO, no el primero que se cierre.
let modalesAbiertos = 0;

// Abre un modal y le da el foco, para que quien navega con teclado no se quede
// escribiendo detrás.
function mostrarModal(id) {
  document.getElementById(id).hidden = false;
  modalesAbiertos += 1;
  document.body.style.overflow = 'hidden';
}
// Cierra un modal.
function ocultarModal(id) {
  document.getElementById(id).hidden = true;
  modalesAbiertos = Math.max(0, modalesAbiertos - 1);
  if (modalesAbiertos === 0) document.body.style.overflow = '';
}

// Deja el formulario en blanco antes de reutilizarlo: el mismo modal sirve para
// crear y para editar, y un valor heredado de la apertura anterior se guardaría
// sin que nadie lo haya escrito.
function limpiarFormulario() {
  document.getElementById('formArticulo').reset();
  document.getElementById('modalArticuloError').hidden = true;
  document.getElementById('campoModelCode').disabled = false;
  document.getElementById('campoStockMinimo').value = 5;
}

// Alta de artículo. Arranca en "producto existente", que es el caso habitual:
// casi siempre se añade una talla a un modelo que ya se vende.
async function abrirModalCrear() {
  articuloEnEdicion = null;
  limpiarFormulario();

  document.getElementById('modalArticuloTitulo').textContent = 'Nuevo artículo';
  document.getElementById('btnGuardarArticulo').textContent = 'Crear artículo';
  document.getElementById('grupoModoProducto').hidden = false;
  document.querySelector('input[name="modoProducto"][value="EXISTENTE"]').checked = true;
  document.getElementById('campoAlmacenGrupo').hidden = false;
  document.getElementById('notaRegistroInventario').hidden = false;

  const { marcas, categorias, proveedores, productos } = await cargarCatalogosSiHaceFalta();
  poblarSelectSimple('campoMarca', marcas, { placeholder: 'Sin marca' });
  poblarSelectSimple('campoCategoria', categorias, { placeholder: 'Sin categoría' });
  poblarProveedores(proveedores);
  poblarSelectSimple('campoProducto', productos);

  actualizarVisibilidadPorModo();
  mostrarModal('modalArticulo');
}

// Edición. Recibe el artículo entero, no su id: la fila ya viene cargada en la
// tabla y volver a pedirla solo añadiría una espera.
async function abrirModalEditar(articulo) {
  articuloEnEdicion = articulo;
  limpiarFormulario();

  document.getElementById('modalArticuloTitulo').textContent = 'Editar artículo';
  document.getElementById('btnGuardarArticulo').textContent = 'Guardar cambios';
  document.getElementById('grupoModoProducto').hidden = true;
  document.getElementById('campoProductoExistente').hidden = true;
  // Editando, la ubicación no se cambia desde acá y la nota sobraría; los
  // umbrales sí se editan, que es "modificar el registro de inventario".
  document.getElementById('campoAlmacenGrupo').hidden = true;
  document.getElementById('notaRegistroInventario').hidden = true;
  mostrarBloqueDefinicionProducto(true);

  const { marcas, categorias, proveedores } = await cargarCatalogosSiHaceFalta();
  poblarSelectSimple('campoMarca', marcas, { placeholder: 'Sin marca' });
  poblarSelectSimple('campoCategoria', categorias, { placeholder: 'Sin categoría' });
  poblarProveedores(proveedores);

  document.getElementById('campoModelCode').value = articulo.product?.model_code ?? '';
  document.getElementById('campoModelCode').disabled = true; // el código de modelo no se reasigna desde aquí
  document.getElementById('campoMarca').value = articulo.product?.brand?.id ?? '';
  document.getElementById('campoNombre').value = articulo.product?.name ?? '';
  document.getElementById('campoCategoria').value = articulo.product?.category?.id ?? '';
  document.getElementById('campoProveedor').value = articulo.product?.supplier?.id ?? '';
  document.getElementById('campoDescripcion').value = articulo.product?.description ?? '';
  document.getElementById('campoPublico').value = articulo.audience === 'NINO' ? 'NINO' : 'ADULTO';
  document.getElementById('campoProveedor').value =
    articulo.supplier_id ?? articulo.product?.supplier_id ?? '';
  bloquearCamposDelModelo(false);

  document.getElementById('campoSku').value = articulo.sku ?? '';
  document.getElementById('campoTalla').value = articulo.size_label ?? '';
  document.getElementById('campoPeso').value = articulo.weight ?? '';
  document.getElementById('campoLargo').value = articulo.length ?? '';
  document.getElementById('campoAncho').value = articulo.width ?? '';
  document.getElementById('campoAlto').value = articulo.height ?? '';

  // Después de volcar las del artículo, no antes: aplicarPublico() completa
  // las que estén vacías con la caja estándar del público y ajusta el rango de
  // tallas. Llamándola antes, el `?? ''` de estas cuatro líneas la deshacía.
  aplicarPublico();
  avisarSiElCostoSupera();
  document.getElementById('campoCosto').value = articulo.cost ?? '';
  document.getElementById('campoPrecio').value = articulo.price ?? '';

  const inv = articulo.inventory?.[0];
  document.getElementById('campoStockMinimo').value = inv?.min_stock ?? 0;
  document.getElementById('campoStockMaximo').value = inv?.max_stock ?? '';

  mostrarModal('modalArticulo');
}

// Cierra y olvida el artículo en edición, que es lo que distingue el modo alta
// del modo edición en el resto del archivo.
function cerrarModalArticulo() {
  ocultarModal('modalArticulo');
  articuloEnEdicion = null;
}

document.getElementById('btnNuevoArticulo').addEventListener('click', abrirModalCrear);
document.getElementById('btnCerrarModalArticulo').addEventListener('click', cerrarModalArticulo);
document.getElementById('btnCancelarArticulo').addEventListener('click', cerrarModalArticulo);
document.getElementById('modalArticulo').addEventListener('click', (e) => {
  if (e.target.id === 'modalArticulo') cerrarModalArticulo(); // clic en el fondo
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !document.getElementById('modalArticulo').hidden) cerrarModalArticulo();
});

// El proveedor elegido, dando de alta el nuevo si hace falta. Se crea aquí y
// no al cambiar el select para no dejar proveedores sueltos cada vez que
// alguien escribe un nombre y se arrepiente.
async function resolverProveedor() {
  const elegido = document.getElementById('campoProveedor').value;
  if (elegido !== NUEVO_PROVEEDOR) return elegido || null;

  const nombre = document.getElementById('campoProveedorNuevo').value.trim();
  if (!nombre) throw new Error('Escribe el nombre del proveedor nuevo.');

  const creado = await CatalogoAPI.crearProveedor(nombre);
  catalogosCache = null; // el proveedor nuevo tiene que salir en la próxima apertura
  return creado.id;
}

// --- Guardar -----------------------------------------------------------

document.getElementById('formArticulo').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  const boton = document.getElementById('btnGuardarArticulo');
  const errorEl = document.getElementById('modalArticuloError');
  const textoOriginalBoton = boton.textContent;
  errorEl.hidden = true;
  boton.disabled = true;
  boton.textContent = 'Guardando…';

  try {
    // El formulario declara required, pattern y máximos desde siempre, pero
    // hasta ahora nadie los aplicaba: llevaba novalidate y no se preguntaba.
    const problema = primerErrorDelFormulario(evento.target);
    if (problema) throw new Error(problema);

    const sku = document.getElementById('campoSku').value.trim();
    const talla = document.getElementById('campoTalla').value.trim();
    const price = parseFloatOrNull(document.getElementById('campoPrecio').value);
    const cost = parseFloatOrNull(document.getElementById('campoCosto').value);
    const weight = parseFloatOrNull(document.getElementById('campoPeso').value);
    const length = parseFloatOrNull(document.getElementById('campoLargo').value);
    const width = parseFloatOrNull(document.getElementById('campoAncho').value);
    const height = parseFloatOrNull(document.getElementById('campoAlto').value);

    // CatalogoAPI.crearArticulo espera camelCase; actualizarItem hace un
    // .update() directo contra la tabla y por eso espera snake_case. Se
    // arman los dos en vez de reutilizar un mismo objeto a medias.
    const repetida = tallaRepetida();
    if (repetida) {
      throw new Error(
        `Ese modelo ya tiene la talla ${repetida.size_label} (${repetida.sku}). ` +
        'Corrige la talla o edita el artículo que ya existe.');
    }

    const supplierId = await resolverProveedor();

    const paraCrearItem = { sku, sizeLabel: talla, price, cost, weight, length, width, height };
    const paraActualizarItem = {
      sku, size_label: talla, price, cost, weight, length, width, height,
      supplier_id: supplierId,
      audience: document.getElementById('campoPublico').value,
    };
    if (cost != null && price != null && cost > price) {
      throw new Error(
        `El costo (${cost}) no puede ser mayor que el precio (${price}): se estaría vendiendo a pérdida.`);
    }

    const minStock = parseInt(document.getElementById('campoStockMinimo').value, 10) || 0;
    const maxStock = parseFloatOrNull(document.getElementById('campoStockMaximo').value);
    if (maxStock != null && maxStock < minStock) {
      throw new Error(`El stock máximo (${maxStock}) no puede ser menor que el mínimo (${minStock}).`);
    }

    if (articuloEnEdicion) {
      await CatalogoAPI.actualizarProducto(articuloEnEdicion.product.id, {
        name: document.getElementById('campoNombre').value.trim(),
        description: document.getElementById('campoDescripcion').value.trim() || null,
        brand_id: document.getElementById('campoMarca').value || null,
        category_id: document.getElementById('campoCategoria').value || null,
      });
      await CatalogoAPI.actualizarItem(articuloEnEdicion.id, paraActualizarItem);

      const inv = articuloEnEdicion.inventory?.[0];
      if (inv) {
        await InventarioAPI.actualizarUmbrales(inv.id, { minStock, maxStock });
      }
      mostrarToast('Artículo actualizado.', 'ok');
    } else {
      const modo = document.querySelector('input[name="modoProducto"]:checked').value;
      let productId;

      if (modo === 'NUEVO') {
        const modelCode = document.getElementById('campoModelCode').value.trim();
        if (!modelCode) throw new Error('El código de modelo es obligatorio para un producto nuevo.');
        const producto = await CatalogoAPI.crearProducto({
          modelCode,
          name: document.getElementById('campoNombre').value.trim(),
          description: document.getElementById('campoDescripcion').value.trim() || null,
          brandId: document.getElementById('campoMarca').value || null,
          categoryId: document.getElementById('campoCategoria').value || null,
          supplierId: document.getElementById('campoProveedor').value || null,
          audience: document.getElementById('campoPublico').value,
        });
        productId = producto.id;
        catalogosCache = null; // el producto nuevo debe aparecer la próxima vez que se abra el selector
      } else {
        productId = document.getElementById('campoProducto').value;
        if (!productId) throw new Error('Elige un producto existente.');
      }

      // Una sola llamada: el artículo y su registro de inventario se crean en
      // la misma transacción. Cuando eran dos, un fallo en la segunda dejaba
      // el artículo creado y sin inventario, imposible de ver y de corregir.
      // La cantidad arranca en 0 a propósito: el stock entra por un movimiento
      // de ENTRADA aprobado, no por el alta del catálogo.
      await CatalogoAPI.crearArticuloConInventario({
        productId,
        ...paraCrearItem,
        warehouseCode: document.getElementById('campoAlmacen').value,
        supplierId,
        audience: document.getElementById('campoPublico').value,
        minStock,
        maxStock,
      });
      mostrarToast('Artículo creado. Registra un movimiento de ENTRADA para cargarle stock.', 'ok');
    }

    cerrarModalArticulo();
    await recargarArticulos();
  } catch (err) {
    errorEl.textContent = traducirError(err, 'No se pudo guardar. Intenta de nuevo.');
    errorEl.hidden = false;
    errorEl.focus();
  } finally {
    boton.disabled = false;
    boton.textContent = textoOriginalBoton;
  }
});

// --- Eliminar (con confirmación) ----------------------------------------

function confirmarEliminarArticulo(articulo) {
  document.getElementById('modalConfirmarTitulo').textContent = 'Eliminar artículo';
  document.getElementById('modalConfirmarMensaje').textContent =
    `¿Eliminar "${articulo.product?.name ?? articulo.sku}" (${articulo.sku})? Si tiene stock o movimientos, quedará pendiente de autorización de un jefe en vez de borrarse directamente.`;

  mostrarModal('modalConfirmar');

  const btnAceptar = document.getElementById('btnAceptarConfirmar');
  const nuevoBoton = btnAceptar.cloneNode(true); // limpia listeners de una confirmación anterior
  // El modal es compartido y el clon hereda el texto que dejó el uso anterior:
  // cada quien declara el suyo o el botón termina diciendo cualquier cosa.
  nuevoBoton.textContent = 'Eliminar';
  btnAceptar.replaceWith(nuevoBoton);

  nuevoBoton.addEventListener('click', async () => {
    nuevoBoton.disabled = true;
    nuevoBoton.textContent = 'Eliminando…';
    try {
      const resultado = await CatalogoAPI.eliminarArticulo(articulo.id, 'Eliminado desde el dashboard');
      ocultarModal('modalConfirmar');
      mostrarToast(resultado.mensaje ?? 'Listo.', resultado.estado === 'ELIMINADO' ? 'ok' : 'info');
      await recargarArticulos();
    } catch (err) {
      mostrarToast(err.message ?? 'No se pudo eliminar.', 'bad');
    } finally {
      nuevoBoton.disabled = false;
      nuevoBoton.textContent = 'Eliminar';
    }
  });
}

document.getElementById('btnCancelarConfirmar').addEventListener('click', () => ocultarModal('modalConfirmar'));

// --- Toasts --------------------------------------------------------------

function mostrarToast(mensaje, tipo = 'info') {
  const cont = document.getElementById('toasts');
  const toast = document.createElement('div');
  toast.className = `toast ${tipo}`;
  toast.textContent = mensaje;
  cont.appendChild(toast);
  setTimeout(() => toast.remove(), 5000);
}

// El SKU y el código de modelo van en mayúscula: la base exige sku = upper(sku)
// y el formato no admite puntos ni signos. La talla, con punto decimal.
normalizarCodigoAlEscribir('campoSku');
normalizarCodigoAlEscribir('campoModelCode');
normalizarTallaAlEscribir('campoTalla');

document.getElementById('campoProducto').addEventListener('change', precargarDesdeProducto);
document.getElementById('campoPublico').addEventListener('change', () => { aplicarPublico(); derivarSku(); });
document.getElementById('campoModelCode').addEventListener('input', derivarSku);
document.getElementById('campoTalla').addEventListener('input', derivarSku);
for (const id of ['campoCosto', 'campoPrecio']) {
  document.getElementById(id).addEventListener('input', avisarSiElCostoSupera);
}
// "+ Nuevo proveedor…" abre el campo del nombre; cualquier otra opción lo
// esconde y lo vacía, para que no quede un nombre a medias que luego se cree
// sin querer.
function actualizarProveedorNuevo() {
  const esNuevo = document.getElementById('campoProveedor').value === NUEVO_PROVEEDOR;
  const campo = document.getElementById('campoProveedorNuevo');
  campo.hidden = !esNuevo;
  campo.required = esNuevo;
  if (!esNuevo) campo.value = '';
  else campo.focus();
}

document.getElementById('campoProveedor').addEventListener('change', actualizarProveedorNuevo);

