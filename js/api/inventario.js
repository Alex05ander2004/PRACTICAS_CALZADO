// Stock y mapa del almacén. Ambas consultas leen vistas (security_invoker),
// así que respetan RLS igual que si se consultaran las tablas directamente.
// Los KPIs del dashboard (total, valor, bajo mínimo...) NO se calculan aquí:
// son agregaciones sobre estos mismos datos y viven en la capa de UI (Fase 4),
// para no duplicar la misma cuenta en dos lugares.
const InventarioAPI = {
  async listarStock() {
    const { data, error } = await supabaseClient
      .from('v_stock_actual')
      .select('*')
      .order('producto');

    if (error) throw error;
    return data;
  },

  // Todas las posiciones del almacén, ocupadas y libres (estado_ocupacion es
  // NULL cuando está libre). Es la consulta que responde "¿dónde meto lo que
  // acaba de llegar?".
  async obtenerMapaAlmacen() {
    const { data, error } = await supabaseClient
      .from('v_mapa_almacen')
      .select('*')
      .order('almacen_code')
      .order('rack')
      .order('posicion');

    if (error) throw error;
    return data;
  },

  async listarStockSinUbicar() {
    const { data, error } = await supabaseClient.from('v_stock_sin_ubicar').select('*');
    if (error) throw error;
    return data;
  },

  // Ubicar o retirar físicamente mercadería. RLS permite escribir aquí a
  // OPERARIO/SUPERVISOR/JEFE; la restricción de "no ocupar el mismo espacio
  // dos veces" y "no superar la capacidad" las hacen los triggers de la BD
  // (position_assignments), así que un error de la base aquí es información
  // real, no un bug: significa que el espacio no estaba disponible.
  async asignarPosicion({ positionId, itemId, quantity, status = 'OCUPADA', notes = null }) {
    const { data, error } = await supabaseClient
      .from('position_assignments')
      .insert({ position_id: positionId, item_id: itemId, quantity, status, notes })
      .select()
      .single();

    if (error) throw error;
    return data;
  },

  // Único camino para que exista una fila de inventory (RLS no da INSERT
  // directo — ver migración 06). warehouseCode: 'ALM-A' | 'BOD-B' | 'BOD-C'.
  async crearRegistroInventario({ itemId, warehouseCode, quantity = 0, minStock = 0, maxStock = null }) {
    const { data, error } = await supabaseClient.rpc('crear_registro_inventario', {
      p_item_id: itemId,
      p_warehouse_code: warehouseCode,
      p_quantity: quantity,
      p_min_stock: minStock,
      p_max_stock: maxStock,
    });
    if (error) throw error;
    return data;
  },

  // Solo min_stock/max_stock son editables aquí — quantity/qty_reserved/
  // qty_incoming no tienen GRANT de columna (migración 05), así que ni
  // intentarlo: aunque se mandaran, Postgres los rechaza con "permission
  // denied for column quantity" antes de que importe qué diga esta función.
  async actualizarUmbrales(inventoryId, { minStock, maxStock }) {
    const { data, error } = await supabaseClient
      .from('inventory')
      .update({ min_stock: minStock, max_stock: maxStock })
      .eq('id', inventoryId)
      .select()
      .single();

    if (error) throw error;
    return data;
  },

  async liberarPosicion(assignmentId) {
    const { data, error } = await supabaseClient
      .from('position_assignments')
      .update({ status: 'LIBERADA', released_at: new Date().toISOString() })
      .eq('id', assignmentId)
      .select()
      .single();

    if (error) throw error;
    return data;
  },
};
