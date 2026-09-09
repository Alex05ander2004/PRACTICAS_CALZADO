// Movimientos de inventario: crear la intención (INSERT, sigue permitido
// directo por RLS) y resolver el workflow siempre por función (aprobar,
// ejecutar, rechazar, revertir). No hay updates directos a status: por diseño,
// RLS no da política de UPDATE sobre inventory_movements — ver el comentario
// en 03_rls.sql, bloque E.8.
const MovimientosAPI = {
  async listar() {
    const { data, error } = await supabaseClient
      .from('v_movimientos_detalle')
      .select('*')
      .order('created_at', { ascending: false });

    if (error) throw error;
    return data;
  },

  // { itemId, inventoryId, positionId, movementType, quantity, reason, notes, expectedQuantity }
  // movementType: 'ENTRADA' | 'SALIDA' | 'AJUSTE'
  // created_by sale de la sesión actual, nunca de un parámetro: la política
  // p_mov_insert exige created_by = auth.uid(), así que mandar cualquier otro
  // valor haría fallar el INSERT (es justamente lo que impide crear un
  // movimiento a nombre de otra persona).
  async crear(datos) {
    const {
      data: { session },
    } = await supabaseClient.auth.getSession();
    if (!session) throw new Error('No hay sesión activa.');

    const { data, error } = await supabaseClient
      .from('inventory_movements')
      .insert({
        item_id: datos.itemId,
        inventory_id: datos.inventoryId ?? null,
        order_id: datos.orderId ?? null,
        position_id: datos.positionId ?? null,
        movement_type: datos.movementType,
        quantity: datos.quantity,
        expected_quantity: datos.expectedQuantity ?? datos.quantity,
        reason: datos.reason ?? null,
        notes: datos.notes ?? null,
        created_by: session.user.id,
      })
      .select()
      .single();

    if (error) throw error;
    return data;
  },

  async aprobar(movementId) {
    const { data, error } = await supabaseClient.rpc('aprobar_movimiento', {
      p_movement_id: movementId,
    });
    if (error) throw error;
    return data;
  },

  // cantidadReal: null = llegó/salió exactamente lo aprobado.
  // quality: 'BUENO' | 'DANADO' | 'CUARENTENA' (solo aplica a ENTRADA)
  async ejecutar(movementId, cantidadReal = null, quality = 'BUENO') {
    const { data, error } = await supabaseClient.rpc('ejecutar_movimiento', {
      p_movement_id: movementId,
      p_cantidad_real: cantidadReal,
      p_quality: quality,
    });
    if (error) throw error;
    return data;
  },

  async rechazar(movementId, motivo) {
    const { data, error } = await supabaseClient.rpc('rechazar_movimiento', {
      p_movement_id: movementId,
      p_motivo: motivo,
    });
    if (error) throw error;
    return data;
  },

  // Solo JEFE (lo valida la función). El motivo es obligatorio: una reversión
  // sin justificación no es auditable.
  async revertir(movementId, motivo) {
    const { data, error } = await supabaseClient.rpc('revertir_movimiento', {
      p_movement_id: movementId,
      p_motivo: motivo,
    });
    if (error) throw error;
    return data;
  },

  async listarDiscrepancias() {
    const { data, error } = await supabaseClient
      .from('discrepancies')
      .select('*')
      .order('created_at', { ascending: false });

    if (error) throw error;
    return data;
  },
};
