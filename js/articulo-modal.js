// Modal de crear/editar artículo, confirmación de eliminación y toasts.
// Fase 6. Depende de CatalogoAPI / InventarioAPI (js/api/) y de
// recargarArticulos() (dashboard.js), pero dashboard.js no depende de nada de
// este archivo salvo llamar a abrirModalEditar/confirmarEliminarArticulo
// desde los botones de cada fila.

let catalogosCache = null;
let articuloEnEdicion = null; // null = creando; objeto de CatalogoAPI.listarArticulos() = editando

function parseFloatOrNull(valor) {
  const n = parseFloat(valor);
  return Number.isFinite(n) ? n : null;
}

async function cargarCatalogosSiHaceFalta() {
  if (catalogosCache) return catalogosCache;
  const [marcas, categorias, proveedores, productos] = await Promise.all([
    CatalogoAPI.listarMarcas(),
    CatalogoAPI.listarCategorias(),
    CatalogoAPI.listarProveedores(),
    CatalogoAPI.listarProductos(),
  ]);
  catalogosCache = { marcas, categorias, proveedores, productos };
  return catalogosCache;
}

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

// --- Mostrar/ocultar bloques según el modo ---------------------------------

function mostrarBloqueDefinicionProducto(mostrar) {
  document.getElementById('bloqueModeloMarca').hidden = !mostrar;
  document.getElementById('grupoNombre').hidden = !mostrar;
  document.getElementById('bloqueCategoriaProveedor').hidden = !mostrar;
  document.getElementById('grupoDescripcion').hidden = !mostrar;
}

function actualizarVisibilidadPorModo() {
  if (articuloEnEdicion) return; // al editar, el modo no aplica: siempre se ve todo

  const modo = document.querySelector('input[name="modoProducto"]:checked')?.value ?? 'EXISTENTE';
  const esNuevo = modo === 'NUEVO';
  document.getElementById('campoProductoExistente').hidden = esNuevo;
  mostrarBloqueDefinicionProducto(esNuevo);
}

document.querySelectorAll('input[name="modoProducto"]').forEach((radio) => {
  radio.addEventListener('change', actualizarVisibilidadPorModo);
});

// --- Abrir / cerrar ----------------------------------------------------

function mostrarModal(id) {
  document.getElementById(id).hidden = false;
}
function ocultarModal(id) {
  document.getElementById(id).hidden = true;
}

function limpiarFormulario() {
  document.getElementById('formArticulo').reset();
  document.getElementById('modalArticuloError').hidden = true;
  document.getElementById('campoModelCode').disabled = false;
  document.getElementById('campoStockMinimo').value = 5;
}

async function abrirModalCrear() {
  articuloEnEdicion = null;
  limpiarFormulario();

  document.getElementById('modalArticuloTitulo').textContent = 'Nuevo artículo';
  document.getElementById('btnGuardarArticulo').textContent = 'Crear artículo';
  document.getElementById('grupoModoProducto').hidden = false;
  document.querySelector('input[name="modoProducto"][value="EXISTENTE"]').checked = true;
  document.getElementById('campoAlmacenGrupo').hidden = false;

  const { marcas, categorias, proveedores, productos } = await cargarCatalogosSiHaceFalta();
  poblarSelectSimple('campoMarca', marcas, { placeholder: 'Sin marca' });
  poblarSelectSimple('campoCategoria', categorias, { placeholder: 'Sin categoría' });
  poblarSelectSimple('campoProveedor', proveedores, { placeholder: 'Sin proveedor' });
  poblarSelectSimple('campoProducto', productos);

  actualizarVisibilidadPorModo();
  mostrarModal('modalArticulo');
}

async function abrirModalEditar(articulo) {
  articuloEnEdicion = articulo;
  limpiarFormulario();

  document.getElementById('modalArticuloTitulo').textContent = 'Editar artículo';
  document.getElementById('btnGuardarArticulo').textContent = 'Guardar cambios';
  document.getElementById('grupoModoProducto').hidden = true;
  document.getElementById('campoProductoExistente').hidden = true;
  document.getElementById('campoAlmacenGrupo').hidden = true;
  mostrarBloqueDefinicionProducto(true);

  const { marcas, categorias, proveedores } = await cargarCatalogosSiHaceFalta();
  poblarSelectSimple('campoMarca', marcas, { placeholder: 'Sin marca' });
  poblarSelectSimple('campoCategoria', categorias, { placeholder: 'Sin categoría' });
  poblarSelectSimple('campoProveedor', proveedores, { placeholder: 'Sin proveedor' });

  document.getElementById('campoModelCode').value = articulo.product?.model_code ?? '';
  document.getElementById('campoModelCode').disabled = true; // el código de modelo no se reasigna desde aquí
  document.getElementById('campoMarca').value = articulo.product?.brand?.id ?? '';
  document.getElementById('campoNombre').value = articulo.product?.name ?? '';
  document.getElementById('campoCategoria').value = articulo.product?.category?.id ?? '';
  document.getElementById('campoProveedor').value = articulo.product?.supplier?.id ?? '';
  document.getElementById('campoDescripcion').value = articulo.product?.description ?? '';

  document.getElementById('campoSku').value = articulo.sku ?? '';
  document.getElementById('campoTalla').value = articulo.size_label ?? '';
  document.getElementById('campoPeso').value = articulo.weight ?? '';
  document.getElementById('campoLargo').value = articulo.length ?? '';
  document.getElementById('campoAncho').value = articulo.width ?? '';
  document.getElementById('campoAlto').value = articulo.height ?? '';
  document.getElementById('campoCosto').value = articulo.cost ?? '';
  document.getElementById('campoPrecio').value = articulo.price ?? '';

  const inv = articulo.inventory?.[0];
  document.getElementById('campoStockMinimo').value = inv?.min_stock ?? 0;
  document.getElementById('campoStockMaximo').value = inv?.max_stock ?? '';

  mostrarModal('modalArticulo');
}

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
    const paraCrearItem = { sku, sizeLabel: talla, price, cost, weight, length, width, height };
    const paraActualizarItem = { sku, size_label: talla, price, cost, weight, length, width, height };
    const minStock = parseInt(document.getElementById('campoStockMinimo').value, 10) || 0;
    const maxStock = parseFloatOrNull(document.getElementById('campoStockMaximo').value);

    if (articuloEnEdicion) {
      await CatalogoAPI.actualizarProducto(articuloEnEdicion.product.id, {
        name: document.getElementById('campoNombre').value.trim(),
        description: document.getElementById('campoDescripcion').value.trim() || null,
        brand_id: document.getElementById('campoMarca').value || null,
        category_id: document.getElementById('campoCategoria').value || null,
        supplier_id: document.getElementById('campoProveedor').value || null,
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
        });
        productId = producto.id;
        catalogosCache = null; // el producto nuevo debe aparecer la próxima vez que se abra el selector
      } else {
        productId = document.getElementById('campoProducto').value;
        if (!productId) throw new Error('Elige un producto existente.');
      }

      const item = await CatalogoAPI.crearArticulo({ productId, ...paraCrearItem });

      // La cantidad arranca en 0 a propósito: el stock real entra por un
      // movimiento ENTRADA (Fase 8), no aquí. Esto es solo el alta del
      // catálogo y sus umbrales de alerta.
      await InventarioAPI.crearRegistroInventario({
        itemId: item.id,
        warehouseCode: document.getElementById('campoAlmacen').value,
        quantity: 0,
        minStock,
        maxStock,
      });
      mostrarToast('Artículo creado. Registra un movimiento de ENTRADA para cargarle stock.', 'ok');
    }

    cerrarModalArticulo();
    await recargarArticulos();
  } catch (err) {
    errorEl.textContent = err.message ?? 'No se pudo guardar. Intenta de nuevo.';
    errorEl.hidden = false;
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
