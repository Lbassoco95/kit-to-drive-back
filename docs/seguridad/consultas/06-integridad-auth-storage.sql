-- ============================================================================
-- Integridad: Auth y Storage (conteos y huellas, sin filas). SOLO LECTURA.
-- Envolver en: begin read only; … rollback;
-- huella_sin_contrasena: id, correo, alta, banned_until, app/user metadata (cambia si se bloquea una cuenta o se marca «debe cambiar contraseña»).
-- huella_contrasenas: md5 de los hashes de contraseña (cambia cuando alguien cambia su contraseña: actividad normal o el script de cambio obligatorio no la cambia).
-- En storage, `activos_no_bloqueados` en las filas de objetos es la SUMA DE BYTES.
-- ============================================================================
select 'auth.users' as objeto, count(*)::text as total,
  count(*) filter (where banned_until is null or banned_until < now())::text as activos_no_bloqueados,
  count(*) filter (where banned_until is not null and banned_until >= now())::text as bloqueados,
  count(*) filter (where email_confirmed_at is not null)::text as confirmados,
  md5(string_agg(id::text||'|'||coalesce(email,'')||'|'||created_at::text||'|'||coalesce(banned_until::text,'')||'|'||coalesce(raw_app_meta_data::text,'')||'|'||coalesce(raw_user_meta_data::text,''), E'\n' order by id)) as huella_sin_contrasena,
  md5(string_agg(id::text||'|'||coalesce(encrypted_password,''), E'\n' order by id)) as huella_contrasenas
from auth.users
union all select 'auth.identities', count(*)::text, null, null, null, md5(string_agg(id::text||'|'||user_id::text||'|'||provider, E'\n' order by id)), null from auth.identities
union all select 'auth.sessions', count(*)::text, count(*) filter (where not_after is null or not_after > now())::text, null, null, null, null from auth.sessions
union all select 'auth.refresh_tokens', count(*)::text, count(*) filter (where not revoked)::text, null, null, null, null from auth.refresh_tokens
union all select 'auth.mfa_factors', count(*)::text, null, null, null, null, null from auth.mfa_factors
union all select 'storage.buckets', count(*)::text, null, null, null, md5(string_agg(id||'|'||public::text||'|'||coalesce(file_size_limit::text,'')||'|'||coalesce(allowed_mime_types::text,''), E'\n' order by id)), null from storage.buckets
union all select 'storage.objects total', count(*)::text, sum(coalesce((metadata->>'size')::bigint,0))::text, null, null, md5(string_agg(bucket_id||'|'||name||'|'||coalesce(metadata->>'size','')||'|'||coalesce(metadata->>'eTag',''), E'\n' order by bucket_id, name)), null from storage.objects
union all select 'storage.objects ['||bucket_id||']', count(*)::text, sum(coalesce((metadata->>'size')::bigint,0))::text, null, null, md5(string_agg(name||'|'||coalesce(metadata->>'size','')||'|'||coalesce(metadata->>'eTag',''), E'\n' order by name)), null from storage.objects group by bucket_id
order by 1;
