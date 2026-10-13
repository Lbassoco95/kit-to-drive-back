-- Subir PDF / comprobante de pago a remisiones-docs fallaba con
-- "new row violates row-level security policy" para quien ve y opera remisiones
-- pero no es admin/ventas/compras (coordinador_ventas, director_ventas,
-- auxiliar_ventas, área comercial). La lectura ya los admitía; la subida no.
--
-- Política ADITIVA: no toca las existentes ("subir docs remisiones admin/ventas",
-- "compras supervisa docs remisiones subir"). Idempotente.
--
-- Alcance (espejo de "leer docs remisiones operativos"):
--   * coordinador_ventas / director_ventas: cualquier remisión.
--   * auxiliar_ventas / área comercial: solo remisiones donde son el vendedor.
-- La carpeta del objeto es el id de la remisión (storage.foldername(name))[1].

drop policy if exists "subir docs remisiones comercial" on storage.objects;

create policy "subir docs remisiones comercial"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'remisiones-docs'
  and public.usuario_activo(auth.uid())
  and (
    public.has_role(auth.uid(), 'coordinador_ventas'::public.app_role)
    or public.has_role(auth.uid(), 'director_ventas'::public.app_role)
    or (
      (
        public.has_role(auth.uid(), 'auxiliar_ventas'::public.app_role)
        or public.es_area(auth.uid(), 'comercial'::public.user_area)
      )
      and exists (
        select 1
        from public.remisiones r
        where r.id::text = (storage.foldername(name))[1]
          and r.vendedor_id = auth.uid()
      )
    )
  )
);
