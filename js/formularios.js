// Lo que comparten todos los formularios: aplicar la validación que ya declara
// el HTML, normalizar los códigos mientras se escriben y traducir los errores
// de la base a algo legible.

// Los <form> llevan novalidate para que el navegador no dibuje sus propios
// globos encima del modal. Las reglas declarativas (required, maxlength,
// pattern, min, max) igual se evalúan: esto las traduce al mismo recuadro donde
// caen los errores que vienen de la base, para que el usuario mire siempre al
// mismo sitio. El title del campo es el mensaje, y por eso está redactado como
// explicación y no como nota al pie.
function primerErrorDelFormulario(form) {
  // Un valor de solo espacios pasa el required del navegador y lo rechaza la
  // base: se recorta antes de preguntar, no después.
  for (const campo of form.querySelectorAll('input[type="text"], input[type="search"], textarea')) {
    campo.value = campo.value.trim();
  }

  // Solo controles y solo visibles: el modal de artículo esconde el nombre y el
  // código de modelo cuando se elige un producto existente, y :invalid los
  // encuentra igual. Exigir un campo que no está en pantalla deja el formulario
  // trabado sin nada que corregir a la vista.
  const campo = [...form.querySelectorAll('input:invalid, select:invalid, textarea:invalid')]
    .find((c) => !c.closest('[hidden]'));
  if (!campo) return null;
  campo.focus();

  const etiqueta = form.querySelector(`label[for="${campo.id}"]`)?.textContent?.trim() ?? 'Un campo';
  const v = campo.validity;
  if (v.valueMissing)   return `Falta completar "${etiqueta}".`;
  if (v.tooLong)        return `"${etiqueta}" no puede pasar de ${campo.maxLength} caracteres.`;
  if (v.rangeUnderflow) return `"${etiqueta}" no puede ser menor que ${campo.min}.`;
  if (v.rangeOverflow)  return `"${etiqueta}" no puede ser mayor que ${campo.max}.`;
  if (v.stepMismatch)   return `"${etiqueta}" tiene que ir de a ${campo.step}.`;
  if (v.badInput)       return `"${etiqueta}" no es un número válido.`;
  return campo.title || `"${etiqueta}" no tiene el formato esperado.`;
}

// Los códigos van en mayúscula y sin caracteres que la base no admite —puntos,
// signos, espacios—. Se corrige al escribir y no al guardar: así no hay que
// adivinar por qué falló, y la base exige literalmente sku = upper(sku).
function normalizarCodigoAlEscribir(id) {
  const campo = document.getElementById(id);
  if (!campo) return;

  campo.addEventListener('input', () => {
    const antes = campo.value;
    const limpio = antes.toUpperCase().replace(/[^A-Z0-9-]/g, '');
    if (limpio === antes) return;

    // El cursor se queda donde estaba, descontando lo que se quitó a su
    // izquierda; sin esto salta al final en cada carácter rechazado.
    const cursor = campo.selectionStart ?? limpio.length;
    campo.value = limpio;
    const corrido = Math.max(0, cursor - (antes.length - limpio.length));
    campo.setSelectionRange(corrido, corrido);
  });
}

// Las tallas se escriben con coma tan seguido como con punto, y la base guarda
// el texto tal cual: "41,5" y "41.5" serían dos tallas distintas.
function normalizarTallaAlEscribir(id) {
  const campo = document.getElementById(id);
  if (!campo) return;
  campo.addEventListener('input', () => {
    if (campo.value.includes(',')) campo.value = campo.value.replace(',', '.');
  });
}

// Los errores de restricción llegan crudos de Postgres ("duplicate key value
// violates unique constraint ..."). Los que un usuario puede provocar desde un
// formulario se traducen; el resto pasa tal cual, porque inventar un mensaje
// para algo que no se previó esconde el problema.
const MENSAJES_DE_RESTRICCION = {
  uq_racks_warehouse_code:  'Ya existe un rack con ese código en este almacén.',
  warehouses_code_key:      'Ya existe un almacén con ese código.',
  inventory_items_sku_key:  'Ya existe un artículo con ese SKU.',
  products_model_code_key:  'Ya existe un producto con ese código de modelo.',
  uq_positions_rack_code:   'Ese código de casillero ya está usado en el rack.',
  uq_items_product_size:    'Ese producto ya tiene un artículo con esa talla.',
  ux_items_product_size_supplier: 'Ese modelo ya tiene esa talla. Corrige la talla o edita el artículo que ya existe.',
  ux_suppliers_code:        'Ya existe un proveedor con ese código corto.',
  suppliers_slug_key:       'Ya existe un proveedor con ese nombre.',
  inventory_items_price_check: 'El precio tiene que ser mayor que cero.',
  inventory_items_cost_check:  'El costo tiene que ser mayor que cero.',
  ck_inventory_max_sobre_min:  'El stock máximo no puede quedar por debajo del mínimo.',
  ck_products_audience:        'El público del modelo tiene que ser adulto o niño.',
};

function traducirError(err, respaldo = 'No se pudo completar la acción.') {
  const texto = err?.message ?? '';
  for (const [restriccion, mensaje] of Object.entries(MENSAJES_DE_RESTRICCION)) {
    if (texto.includes(restriccion)) return mensaje;
  }
  return texto || respaldo;
}
