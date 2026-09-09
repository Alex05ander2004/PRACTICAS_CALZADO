// Dropdown propio sobre un <select> nativo existente ("progressive enhancement"):
// el <select> sigue siendo la fuente de verdad (su .value y su evento 'change'
// no cambian), así que el resto del dashboard no se entera de que existe esto.
// Se construyó porque la lista abierta de un <select> nativo la dibuja el
// sistema operativo y NINGÚN navegador permite darle border-radius — es la
// única forma de que se vea consistente con el resto de la interfaz.

function mejorarSelect(id) {
  const nativo = document.getElementById(id);
  if (!nativo || nativo.dataset.mejorado) return;
  nativo.dataset.mejorado = '1';
  nativo.tabIndex = -1; // el foco de teclado va al botón propio, no al <select> oculto

  const contenedor = document.createElement('div');
  contenedor.className = 'dselect';

  const boton = document.createElement('button');
  boton.type = 'button';
  boton.className = 'dselect-trigger';
  boton.setAttribute('aria-haspopup', 'listbox');
  boton.setAttribute('aria-expanded', 'false');

  const etiqueta = document.createElement('span');
  etiqueta.className = 'dselect-label';
  const flecha = document.createElement('span');
  flecha.className = 'dselect-flecha';
  flecha.setAttribute('aria-hidden', 'true');
  boton.append(etiqueta, flecha);

  const lista = document.createElement('ul');
  lista.className = 'dselect-list';
  lista.setAttribute('role', 'listbox');
  lista.hidden = true;

  contenedor.append(boton, lista);
  nativo.insertAdjacentElement('afterend', contenedor);
  nativo.classList.add('dselect-nativo-oculto');

  let indiceActivo = -1;

  function opciones() {
    return [...lista.querySelectorAll('.dselect-opcion')];
  }

  function reconstruir() {
    lista.innerHTML = '';
    [...nativo.options].forEach((opt) => {
      const li = document.createElement('li');
      li.className = 'dselect-opcion';
      li.setAttribute('role', 'option');
      li.dataset.valor = opt.value;
      li.textContent = opt.textContent;
      const seleccionada = opt.value === nativo.value;
      li.setAttribute('aria-selected', String(seleccionada));
      if (seleccionada) li.classList.add('activa');
      li.addEventListener('click', () => seleccionar(opt.value));
      lista.appendChild(li);
    });
    etiqueta.textContent = nativo.options[nativo.selectedIndex]?.textContent ?? '';
    indiceActivo = opciones().findIndex((li) => li.classList.contains('activa'));
  }

  function seleccionar(valor) {
    nativo.value = valor;
    nativo.dispatchEvent(new Event('change', { bubbles: true }));
    reconstruir();
    cerrar();
    boton.focus();
  }

  function resaltar(indice) {
    const nodos = opciones();
    nodos.forEach((li) => li.classList.remove('resaltada'));
    if (nodos[indice]) {
      nodos[indice].classList.add('resaltada');
      nodos[indice].scrollIntoView({ block: 'nearest' });
    }
    indiceActivo = indice;
  }

  function abrir() {
    lista.hidden = false;
    boton.setAttribute('aria-expanded', 'true');
    const activa = opciones().findIndex((li) => li.classList.contains('activa'));
    resaltar(activa >= 0 ? activa : 0);
  }

  function cerrar() {
    lista.hidden = true;
    boton.setAttribute('aria-expanded', 'false');
  }

  boton.addEventListener('click', (e) => {
    e.stopPropagation();
    lista.hidden ? abrir() : cerrar();
  });

  boton.addEventListener('keydown', (e) => {
    const nodos = opciones();
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      if (lista.hidden) return abrir();
      resaltar(Math.min(indiceActivo + 1, nodos.length - 1));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      if (lista.hidden) return abrir();
      resaltar(Math.max(indiceActivo - 1, 0));
    } else if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      if (lista.hidden) return abrir();
      if (nodos[indiceActivo]) seleccionar(nodos[indiceActivo].dataset.valor);
    } else if (e.key === 'Escape') {
      cerrar();
    }
  });

  document.addEventListener('click', (e) => {
    if (!contenedor.contains(e.target)) cerrar();
  });

  reconstruir();
  nativo._dselectSync = reconstruir;
}

// Llamar después de reconstruir las <option> de un <select> ya mejorado
// (por ejemplo, cuando poblarSelectDesdeArticulos cambia las categorías
// disponibles), o después de cambiar nativo.value a mano (botón "Limpiar").
function sincronizarSelectMejorado(id) {
  const nativo = document.getElementById(id);
  if (nativo?._dselectSync) nativo._dselectSync();
}
