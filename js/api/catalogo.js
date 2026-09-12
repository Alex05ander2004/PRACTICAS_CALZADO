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
    const { data, error } = await supabaseClient
      .from('suppliers')
      .select('id, name, code')
      .eq('is_active', true)
      .order('name');
    if (error) throw error;
    return data;
  },

  // Alta de proveedor desde el formulario de artículo, para no obligar a salir
  // a otra pantalla cuando llega mercadería de alguien nuevo. El slug y el
  // código corto se derivan del nombre porque son detalle interno: el slug lo
  // exige la tabla en minúsculas y con guiones, y el código es el que usa el
  // SKU. RLS ya limita esto a SUPERVISOR o JEFE (p_suppliers_write).
  async crearProveedor(nombre) {
    const limpio = nombre.trim();
    const sinTildes = limpio.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
    const slug = sinTildes.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
    const raiz = sinTildes.toUpperCase().replace(/[^A-Z0-9]/g, '');

    if (!slug) throw new Error('El nombre del proveedor tiene que tener alguna letra o número.');

    // El código son 3 caracteres, pero es único: si ya está tomado se prueba
    // alargándolo antes que fallar con un error de restricción.
    const { data: existentes } = await supabaseClient.from('suppliers').select('code');
    const tomados = new Set((existentes ?? []).map((s) => s.code));
    let code = raiz.slice(0, 3).padEnd(2, '0');
    for (let n = 4; tomados.has(code) && n <= 6; n += 1) code = raiz.slice(0, n).padEnd(n, '0');
    for (let n = 2; tomados.has(code) && n < 100; n += 1) code = (raiz.slice(0, 2) + n).slice(0, 6);

    const { data, error } = await supabaseClient
      .from('suppliers')
      .insert({ slug, name: limpio, code })
      .select('id, name, code')
      .single();

    if (error) throw error;
    return data;
  },

  // Todos los códigos de modelo, INCLUIDOS los de productos en la papelera:
  // model_code es único sin mirar deleted_at, así que sugerir el de uno
  // borrado daría un duplicado al guardar.
  async codigosDeModeloUsados() {
    const { data, error } = await supabaseClient.from('products').select('model_code');
    if (error) throw error;
    return data.map((p) => p.model_code);
  },

  // Para el selector "producto existente" del formulario de la Fase 6: solo
  // lo mínimo para identificar el modelo, no sus variantes.
  // Trae los datos que el alta de artículo precarga cuando se le agrega una
  // talla a un modelo que ya existe: sin ellos el formulario mostraba marca,
  // categoría y proveedor en blanco, como si el modelo no los tuviera.
  async listarProductos() {
    const { data, error } = await supabaseClient
      .from('products')
      .select('id, model_code, name, description, audience, brand_id, category_id, supplier_id')
      .is('deleted_at', null)
      .order('name');
    if (error) throw error;
    return data;
  },

  // Un artículo = una fila de inventory_items con su producto y su stock
  // embebidos. inventory es un arreglo porque el modelo soporta stock por
  // almacén; con un solo almacén (caso base del README) trae un elemento.
  async listarArticulos() {
    // Paginado por lo mismo que el mapa: pasadas las 1000 filas, PostgREST
    // corta sin avisar. id desempata artículos creados en el mismo instante.
    return traerTodasLasFilas(() => supabaseClient
      .from('inventory_items')
      .select(
        `
        id, sku, size_label, size_system, price, cost, weight, length, width, height, is_active,
        audience, supplier_id,
        supplier:suppliers ( id, name, code ),
        product:products (
          id, model_code, name, description, audience, supplier_id,
          brand:brands ( id, name ),
          category:categories ( id, name ),
          supplier:suppliers ( id, name )
        ),
        inventory ( id, warehouse_id, quantity, qty_reserved, qty_incoming, min_stock, max_stock )
      `
      )
      .is('deleted_at', null)
      .order('created_at', { ascending: false })
      .order('id'));
  },

  async obtenerArticulo(itemId) {
    const { data, error } = await supabaseClient
      .from('inventory_items')
      .select(
        `
        id, sku, size_label, size_system, price, cost, weight, length, width, height, is_active,
        audience, supplier_id,
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
        audience: datos.audience ?? 'ADULTO',
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

  // El alta que usa el formulario: crea el artículo Y su registro de
  // inventario en una sola transacción (migración 26). Antes eran dos
  // llamadas, y cuando la segunda fallaba quedaba un artículo sin inventario:
  // sin almacén, sin umbrales y fuera del dashboard.
  async crearArticuloConInventario(datos) {
    const { data, error } = await supabaseClient.rpc('crear_articulo_con_inventario', {
      p_product_id: datos.productId,
      p_sku: datos.sku,
      p_size_label: datos.sizeLabel,
      p_warehouse_code: datos.warehouseCode,
      p_size_system: datos.sizeSystem ?? 'EU',
      p_price: datos.price ?? null,
      p_cost: datos.cost ?? null,
      p_weight: datos.weight ?? null,
      p_length: datos.length ?? null,
      p_width: datos.width ?? null,
      p_height: datos.height ?? null,
      p_min_stock: datos.minStock ?? 0,
      p_max_stock: datos.maxStock ?? null,
      p_supplier_id: datos.supplierId ?? null,
      p_audience: datos.audience ?? null,
    });
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
