// Plantilla de configuración. Copia este archivo como config.js y completa tus
// datos (Project Settings -> API en el dashboard de Supabase).
//
// La anon key NO es secreta: está diseñada para vivir en el frontend. Quien la
// protege es RLS (supabase/migrations/03_rls.sql), no mantenerla oculta.
// La service_role key SÍ es secreta y JAMÁS debe aparecer en este archivo ni
// en ningún código que corra en el navegador: salta todas las políticas RLS.
const SUPABASE_CONFIG = {
  url: 'https://TU-PROYECTO.supabase.co',
  anonKey: 'TU-ANON-KEY-AQUI',
};
