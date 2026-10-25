-- ============================================================================
-- Datos SINTÉTICOS para el ensayo (solo réplica local; nunca producción ni QA).
-- Inserta una fila de relleno en las tablas que usan los recorridos por rol,
-- creando antes las filas padre que pidan las llaves foráneas. Todo valor es
-- inventado ('sintético', 0, fechas de hoy): no hay ningún dato real.
-- Una tabla cuya fila no se pueda crear (restricción CHECK, trigger) se omite y
-- se reporta con RAISE NOTICE; el ensayo sigue.
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS ensayo;

CREATE OR REPLACE FUNCTION ensayo.fila(_tabla regclass, _prof integer DEFAULT 0) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  c record; cols text[] := '{}'; vals text[] := '{}'; v text; fk record; padre uuid; nuevo uuid;
BEGIN
  IF _prof > 3 THEN RETURN NULL; END IF;
  FOR c IN
    SELECT a.attname, a.atttypid, format_type(a.atttypid, a.atttypmod) AS tipo, t.typtype, t.typcategory
      FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
     WHERE a.attrelid = _tabla AND a.attnum > 0 AND NOT a.attisdropped AND a.attnotnull
       AND NOT EXISTS (SELECT 1 FROM pg_attrdef d WHERE d.adrelid = a.attrelid AND d.adnum = a.attnum)
       AND a.attgenerated = ''
  LOOP
    SELECT co.confrelid::regclass AS padre_tabla INTO fk
      FROM pg_constraint co JOIN pg_attribute a2 ON a2.attrelid = co.conrelid AND a2.attname = c.attname
     WHERE co.conrelid = _tabla AND co.contype = 'f' AND array_length(co.conkey, 1) = 1 AND a2.attnum = co.conkey[1] LIMIT 1;
    IF fk.padre_tabla IS NOT NULL THEN
      IF fk.padre_tabla::text = 'auth.users' THEN
        SELECT id INTO padre FROM auth.users ORDER BY created_at LIMIT 1;
      ELSE
        EXECUTE format('SELECT id FROM %s LIMIT 1', fk.padre_tabla) INTO padre;
        IF padre IS NULL THEN padre := ensayo.fila(fk.padre_tabla, _prof + 1); END IF;
      END IF;
      v := quote_literal(padre);
    ELSIF c.typtype = 'e' THEN
      EXECUTE format('SELECT quote_literal(enumlabel) FROM pg_enum WHERE enumtypid = %s ORDER BY enumsortorder LIMIT 1', c.atttypid) INTO v;
    ELSIF c.tipo = 'uuid' THEN v := quote_literal(gen_random_uuid());
    ELSIF c.typcategory = 'N' THEN v := '1';
    ELSIF c.tipo = 'boolean' THEN v := 'false';
    ELSIF c.typcategory = 'D' THEN v := 'now()';
    ELSIF c.tipo = 'date' THEN v := 'current_date';
    ELSIF c.tipo LIKE 'jsonb%' OR c.tipo LIKE 'json%' THEN v := quote_literal('{}');
    ELSIF c.typcategory = 'A' THEN v := quote_literal('{}');
    ELSE v := quote_literal('sintético ' || left(md5(random()::text), 6));
    END IF;
    cols := cols || quote_ident(c.attname); vals := vals || v;
  END LOOP;
  IF array_length(cols, 1) IS NULL THEN
    EXECUTE format('INSERT INTO %s DEFAULT VALUES RETURNING id', _tabla) INTO nuevo;
  ELSE
    EXECUTE format('INSERT INTO %s (%s) VALUES (%s) RETURNING id', _tabla, array_to_string(cols, ','), array_to_string(vals, ',')) INTO nuevo;
  END IF;
  RETURN nuevo;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'ensayo.fila(%) omitida: % %', _tabla, SQLSTATE, SQLERRM;
  RETURN NULL;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['clientes','remisiones','movimientos_financieros','almacen_refacciones_productos',
                           'cuentas_por_cobrar','motocarros','contenedores','crm_oportunidades','bitacora_eventos','avisos'] LOOP
    PERFORM ensayo.fila(('public.' || t)::regclass);
  END LOOP;
END $$;
