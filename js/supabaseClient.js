// Cliente único de Supabase, compartido por todos los módulos de js/api/.
// Depende de que el HTML cargue, EN ESTE ORDEN:
//   1. https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2  (define window.supabase)
//   2. js/config.js                                          (define SUPABASE_CONFIG)
//   3. este archivo                                          (define supabaseClient)
if (typeof SUPABASE_CONFIG === 'undefined') {
  throw new Error(
    'Falta js/config.js. Copia js/config.example.js como js/config.js y completa tu URL y anon key de Supabase.'
  );
}

const supabaseClient = window.supabase.createClient(
  SUPABASE_CONFIG.url,
  SUPABASE_CONFIG.anonKey
);

// PostgREST corta cada respuesta en 1000 filas (el max-rows de Supabase) y lo
// hace en silencio: sin error ni aviso, lo que pasa de ahí simplemente no llega.
// Con 3 208 casilleros, el mapa perdía todo BOD-B y BOD-C. Esto pide de a
// páginas avanzando por las filas que de verdad llegaron, y para recién con una
// página vacía: si el tope del proyecto fuera menor que porPagina, parar ante la
// primera página incompleta volvería a perder filas.
// construirConsulta arma la consulta de nuevo en cada página (un builder de
// supabase-js no se reusa) y tiene que ordenar por algo único: con empates, dos
// páginas pueden repetir o saltarse filas en el borde.
async function traerTodasLasFilas(construirConsulta, porPagina = 1000) {
  const filas = [];
  for (let desde = 0; ; ) {
    const { data, error } = await construirConsulta().range(desde, desde + porPagina - 1);
    if (error) throw error;
    if (data.length === 0) return filas;
    filas.push(...data);
    desde += data.length;
  }
}
