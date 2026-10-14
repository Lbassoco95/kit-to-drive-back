-- Función comercial de cada persona: vendedor, administrativo, o las dos.
--
-- Hasta hoy los selectores de «Asignar a vendedor» (Remisiones, CRM) listaban a
-- todos los perfiles activos o a toda el área comercial, así que aparecían
-- también las personas administrativas (p. ej. Atenea, Ana Karen). El tipo de
-- usuario (operador / supervisor / admin) no distingue eso: es otra dimensión.
--
-- Dos banderas independientes: una persona puede ser vendedora, administrativa
-- o ambas. Idempotente.

alter table public.profiles
  add column if not exists es_vendedor boolean not null default false,
  add column if not exists es_administrativo boolean not null default false;

comment on column public.profiles.es_vendedor is
  'Aparece en las listas de vendedores (asignar vendedor, equipo de ventas, CRM).';
comment on column public.profiles.es_administrativo is
  'Personal administrativo del área comercial. Puede ser también vendedor.';

-- Respaldo inicial: todo el que ya está en el área comercial era, de hecho,
-- parte del equipo de ventas.
update public.profiles p
   set es_vendedor = true
  from public.user_roles r
 where r.user_id = p.id
   and r.area = 'comercial'
   and p.es_vendedor = false
   and p.es_administrativo = false;

-- Atenea y Ana Karen son administrativas, no vendedoras. Si alguna también
-- vende, se enciende «Vendedor» desde Usuarios.
update public.profiles
   set es_administrativo = true,
       es_vendedor = false
 where lower(email) in ('athenea.portilla@dazon.mx', 'ana.rivas@dazon.mx');

create index if not exists idx_profiles_es_vendedor
  on public.profiles (nombre_completo) where es_vendedor;
