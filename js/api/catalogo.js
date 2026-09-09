// Productos (modelo, sin talla), artículos (variante = modelo + talla) y los
// catálogos de apoyo (marca, categoría, proveedor).
//
// products -> inventory_items: un modelo tiene varias tallas. El formulario de
// edición del README junta campos de ambas tablas (nombre/categoría son del
// producto; SKU/precio/costo son de la variante), así que se exponen updates
// separados y quien llama decide cuáles ejecutar según qué cambió.
const CatalogoAPI = {
  async listarMarcas() {
    const { data, error } = await supabaseClient.from('brands').select('id, name').order('name');
    if (error) throw error;
    return data;
  },

  async listarCategorias() {
    const { data, error } = await supabaseClient.from('categories').select('id, name').order('name');
    if (error) throw error;
    return data;
  },

  async listarProveedores() {
    const { data, error } = await supabaseClient.from('suppliers').select('id, name').order('name');
    if (error) throw error;
    return data;
  },

  // Un artículo = una fila de inventory_items con su producto y su stock
  // embebidos. inventory es un arreglo porque el modelo soporta stock por
  // almacén; con un solo almacén (caso base del README) trae un elemento.
  async listarArticulos() {
    const { data, error } = await supabaseClient
      .from('inventory_items')
      .select(
        `
        id, sku, size_label, size_system, price, cost, weight, length, width, height, is_active,
        product:products (
          id, model_code, name, description,
          brand:brands ( id, name ),
          category:categories ( id, name ),
          supplier:suppliers ( id, name )
        ),
        inventory ( id, warehouse_id, quantity, qty_reserved, qty_incoming, min_stock, max_stock )
      `
      )
      .is('deleted_at', null)
      .order('created_at', { ascending: false });

    if (error) throw error;
    return data;
  },

  async obtenerArticulo(itemId) {
    const { data, error } = await supabaseClient
      .from('inventory_items')
      .select(
        `
        id, sku, size_label, size_system, price, cost, weight, length, width, height, is_active,
        product:products (
          id, model_code, name, description, brand_id, category_id, supplier_id
        ),
        inventory ( id, warehouse_id, quantity, qty_reserved, qty_incoming, min_stock, max_stock )
      `
      )
      .eq('id', itemId)
      .single();

    if (error) throw error;
    return data;
  },

  // { modelCode, name, description, brandId, categoryId, supplierId }
  async crearProducto(datos) {
    const { data, error } = await supabaseClient
      .from('products')
      .insert({
        model_code: datos.modelCode,
        name: datos.name,
        description: datos.description ?? null,
        brand_id: datos.brandId ?? null,
        category_id: datos.categoryId ?? null,
        supplier_id: datos.supplierId ?? null,
      })
      .select()
      .single();

    if (error) throw error;
    return data;
  },

  // { productId, sku, sizeLabel, sizeSystem, price, cost, weight, length, width, height }
  async crearArticulo(datos) {
    const { data, error } = await supabaseClient
      .from('inventory_items')
      .insert({
        product_id: datos.productId,
        sku: datos.sku,
        size_label: datos.sizeLabel,
        size_system: datos.sizeSystem ?? 'EU',
        price: datos.price ?? null,
        cost: datos.cost ?? null,
        weight: datos.weight ?? null,
        length: datos.length ?? null,
        width: datos.width ?? null,
        height: datos.height ?? null,
      })
      .select()
      .single();

    if (error) throw error;
    return data;
  },

  async actualizarProducto(productId, cambios) {
    const { data, error } = await supabaseClient
      .from('products')
      .update(cambios)
      .eq('id', productId)
      .select()
      .single();

    if (error) throw error;
    return data;
  },

  async actualizarItem(itemId, cambios) {
    const { data, error } = await supabaseClient
      .from('inventory_items')
      .update(cambios)
      .eq('id', itemId)
      .select()
      .single();

    if (error) throw error;
    return data;
  },

  // No es un DELETE: pasa por la RPC, que bloquea si hay stock físico y, si
  // quien llama no es JEFE, encola la baja en approval_requests en vez de
  // ejecutarla (ver supabase/migrations/02_mejoras_operativas.sql, fn_eliminar_articulo).
  async eliminarArticulo(itemId, motivo) {
    const { data, error } = await supabaseClient.rpc('eliminar_articulo', {
      p_item_id: itemId,
      p_motivo: motivo,
    });
    if (error) throw error;
    return data; // { estado: 'ELIMINADO' | 'PENDIENTE_APROBACION', mensaje }
  },
};
