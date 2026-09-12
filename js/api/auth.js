// Sesión y perfil del usuario actual.
//
// RLS depende de que exista una sesión real de Supabase Auth: sin ella,
// auth.uid() es NULL y fn_rol_actual() no resuelve a ningún rol, así que las
// políticas bloquean todo. No hay forma de "probar el dashboard" sin antes
// iniciar sesión con un usuario creado en Authentication -> Users.
const AuthAPI = {
  async iniciarSesion(email, password) {
    const { data, error } = await supabaseClient.auth.signInWithPassword({ email, password });
    if (error) throw error;
    return data;
  },

  async cerrarSesion() {
    const { error } = await supabaseClient.auth.signOut();
    if (error) throw error;
  },

  async obtenerSesion() {
    const { data, error } = await supabaseClient.auth.getSession();
    if (error) throw error;
    return data.session;
  },

  // El perfil trae el rol (profiles.role), que es lo que decide qué puede
  // hacer esta persona en la UI: mostrar u ocultar el botón "Aprobar",
  // habilitar "Revertir" solo para JEFE, etc. La fuente de verdad del permiso
  // sigue siendo RLS en el servidor; esto es solo para no mostrar botones que
  // el backend va a rechazar de todas formas.
  async obtenerPerfilActual() {
    const sesion = await this.obtenerSesion();
    if (!sesion) return null;

    const { data, error } = await supabaseClient
      .from('profiles')
      .select('id, full_name, email, role, max_movement_qty')
      .eq('id', sesion.user.id)
      .single();

    if (error) throw error;
    return data;
  },

  // El equipo completo. La política p_profiles_select deja leerlo a cualquier
  // usuario con rol (el dashboard necesita resolver "aprobado por Ana Jefa"),
  // pero la sección Equipo solo se le muestra al jefe: es el único que puede
  // cambiar algo de aquí.
  async listarMiembros() {
    const { data, error } = await supabaseClient
      .from('profiles')
      .select('id, full_name, email, role, is_active, max_movement_qty, created_at')
      .order('full_name');

    if (error) throw error;
    return data;
  },

  // Cambiar rol, tope o alta/baja. Quien no sea JEFE es rechazado dos veces:
  // por la política p_profiles_update y por el trigger
  // trg_profiles_no_autoascenso, que además impide subirse el rol a uno mismo.
  async actualizarMiembro(id, cambios) {
    const { data, error } = await supabaseClient
      .from('profiles')
      .update(cambios)
      .eq('id', id)
      .select()
      .single();

    if (error) throw error;
    return data;
  },

  // callback(evento, sesion) — usar para redirigir a login al cerrar sesión,
  // o refrescar la UI cuando el usuario inicia sesión en otra pestaña.
  onCambioSesion(callback) {
    return supabaseClient.auth.onAuthStateChange(callback);
  },
};
