// Alertas del sistema (stock bajo, capacidad, vencimientos...). Se generan
// solas por trigger en la base de datos — ver docs/ANALISIS-OPERATIVO.md §4 —
// así que esta capa solo lee y reconoce, nunca crea una alerta a mano.
const AlertasAPI = {
  async listarActivas() {
    const { data, error } = await supabaseClient
      .from('v_alertas_activas')
      .select('*');

    if (error) throw error;
    return data;
  },

  // "Me hago cargo de esto." No la cierra: solo dice quién la vio. Se cierra
  // sola cuando la condición que la disparó desaparece (fn_cerrar_alerta).
  async reconocer(alertId) {
    const { data, error } = await supabaseClient.rpc('reconocer_alerta', {
      p_alert_id: alertId,
    });
    if (error) throw error;
    return data;
  },

  async listarMovimientosVencidos() {
    const { data, error } = await supabaseClient.from('v_movimientos_vencidos').select('*');
    if (error) throw error;
    return data;
  },
};

// Solicitudes de autorización escalada (maker-checker): eliminar un artículo,
// revertir, ajustes fuera de umbral, etc. La mayoría se generan solas desde
// otra RPC (por ejemplo eliminar_articulo); esta capa las lista y resuelve.
const AprobacionesAPI = {
  async listarPendientes() {
    const { data, error } = await supabaseClient
      .from('approval_requests')
      .select('*')
      .eq('status', 'PENDIENTE')
      .order('created_at');

    if (error) throw error;
    return data;
  },

  async resolver(requestId, aprobar, nota = null) {
    const { data, error } = await supabaseClient.rpc('resolver_aprobacion', {
      p_request_id: requestId,
      p_aprobar: aprobar,
      p_nota: nota,
    });
    if (error) throw error;
    return data;
  },
};
