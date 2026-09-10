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

  // Grafo de ruteo: nodos (un ENTRADA por almacén + un nodo por rack, con
  // coordenadas reales) y aristas (pasillos caminables, con su distancia).
  // Es poco dato (~13 nodos, ~18 aristas en los 3 almacenes juntos) así que
  // se trae todo de una vez y se filtra por almacén en el cliente.
  // Geometría del plano: dimensiones de cada almacén + el rectángulo que
  // ocupa cada rack sobre la grilla. Con esto solo alcanza para dibujar el
  // plano y para calcular rutas: los pasillos son, literalmente, las celdas
  // que ningún rack ocupa.
  async obtenerLayout() {
    const [almacenes, racks] = await Promise.all([
      supabaseClient
        .from('warehouses')
        .select('id, code, name, grid_ancho, grid_alto, entrada_x, entrada_y')
        .order('code'),
      supabaseClient
        .from('racks')
        .select('id, code, warehouse_id, grid_x, grid_y, grid_ancho, grid_alto, niveles')
        .order('code'),
    ]);
    if (almacenes.error) throw almacenes.error;
    if (racks.error) throw racks.error;
    return { almacenes: almacenes.data, racks: racks.data };
  },

  // Medir el local y cargarlo. Se niega a achicar el plano por debajo de un
  // rack existente (la función nombra cuáles estorban); la entrada, en cambio,
  // se reacomoda sola porque es una referencia del plano, no mercadería.
  async redimensionarAlmacen(warehouseCode, { gridAncho, gridAlto }) {
    const { data, error } = await supabaseClient.rpc('redimensionar_almacen', {
      p_warehouse_code: warehouseCode,
      p_grid_ancho: gridAncho,
      p_grid_alto: gridAlto,
    });
    if (error) throw error;
    return data;
  },

  // Cuántas cajas de calzado entran en un rack de esas medidas con esos pisos.
  // El cálculo vive en la base (migración 11) para que la cifra que se muestra
  // en el editor sea exactamente la que se va a grabar.
  async estimarCapacidadRack({ gridAncho, gridAlto, niveles, slotsPorNivel }) {
    const { data, error } = await supabaseClient.rpc('estimar_capacidad_rack', {
      p_grid_ancho: gridAncho,
      p_grid_alto: gridAlto,
      p_niveles: niveles,
      p_slots_por_nivel: slotsPorNivel,
    });
    if (error) throw error;
    return data; // { frente, fondo, posiciones, cajas, por_nivel: [{nivel, cajas}] }
  },

  // Declarar los pisos del rack y cuántos casilleros tiene cada uno. Solo
  // agrega los que faltan: nunca renumera una posición existente, porque su
  // código ya aparece en el kardex.
  async configurarRack(rackId, { niveles, slotsPorNivel }) {
    const { data, error } = await supabaseClient.rpc('configurar_rack', {
      p_rack_id: rackId,
      p_niveles: niveles,
      p_slots_por_nivel: slotsPorNivel,
    });
    if (error) throw error;
    return data; // { estado, posiciones, cajas, mensaje }
  },

  // Guarda la posición/tamaño de un rack movido en el editor. Si el resultado
  // se sale del plano o pisa otro rack, el trigger trg_racks_geometria lo
  // rechaza y el error llega tal cual a la UI.
  async actualizarGeometriaRack(rackId, { gridX, gridY, gridAncho, gridAlto }) {
    const { data, error } = await supabaseClient
      .from('racks')
      .update({ grid_x: gridX, grid_y: gridY, grid_ancho: gridAncho, grid_alto: gridAlto })
      .eq('id', rackId)
      .select()
      .single();

    if (error) throw error;
    return data;
  },

  // Crea el rack Y sus posiciones en una sola transacción: un rack sin
  // posiciones es un mueble que no puede guardar nada. Las posiciones se
  // reparten entre los niveles, y el nivel 1 de cualquier rack es el que
  // admite calzado infantil (migración 04).
  async crearRack({ warehouseCode, code, gridX, gridY, gridAncho, gridAlto, niveles, slotsPorNivel }) {
    const { data, error } = await supabaseClient.rpc('crear_rack', {
      p_warehouse_code: warehouseCode,
      p_code: code,
      p_grid_x: gridX,
      p_grid_y: gridY,
      p_grid_ancho: gridAncho,
      p_grid_alto: gridAlto,
      p_niveles: niveles,
      p_slots_por_nivel: slotsPorNivel,
    });
    if (error) throw error;
    return data;
  },

  // Se niega si el rack tiene mercadería ubicada o historial de movimientos:
  // borrarlo dejaría el kardex apuntando a posiciones inexistentes.
  async eliminarRack(rackId) {
    const { data, error } = await supabaseClient.rpc('eliminar_rack', { p_rack_id: rackId });
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
