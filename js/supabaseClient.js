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
