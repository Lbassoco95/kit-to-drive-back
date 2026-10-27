#!/usr/bin/env python3
"""Pinta en texto la matriz acción × rol de dos corridas (producción hoy / después de lo planeado).
Uso: render-matriz.py hoy.json despues.json > tablas.md"""
import json, sys
H = json.load(open(sys.argv[1])); D = json.load(open(sys.argv[2]))
act = list(H['actores'])
COD = {'SUPER ADMIN': 'SA', 'direccion/admin': 'DA', 'direccion/supervisor': 'DS', 'direccion/operador': 'DO',
       'comercial/admin': 'CA', 'comercial/supervisor': 'CS', 'comercial/operador': 'CV', 'comercial/operador+administrativo': 'CD',
       'administracion/admin': 'AA', 'administracion/supervisor': 'AS', 'administracion/operador': 'AO',
       'fabrica/admin': 'FA', 'fabrica/supervisor': 'FS', 'fabrica/operador': 'FO',
       'almacen_logistica/admin': 'LA', 'almacen_logistica/supervisor': 'LS', 'almacen_logistica/operador': 'LO',
       'compras/admin': 'PA', 'compras/supervisor': 'PS', 'compras/operador': 'PO',
       'inactivo (comercial/operador)': 'IN', 'sin rol asignado': 'SR'}
orden = [k for k in COD if k in act]
def sim(c): return 'P' if c['clase'] == 'OK' and c['base'] == 'permite' else ('.' if c['clase'] == 'OK' else ('!' if c['clase'] == 'BRECHA' else 'u'))
print('Columnas (en este orden): ' + ' '.join(COD[k] for k in orden) + '\n')
dominios = []
for aid, i in H['acciones'].items():
    if i['dominio'] not in dominios: dominios.append(i['dominio'])
for dom in dominios:
    print(f'### {dom}\n\n```')
    print(f"{'id':6}{'HOY':{len(orden)+1}}{'DESPUÉS':{len(orden)+1}} acción")
    for aid, i in H['acciones'].items():
        if i['dominio'] != dom: continue
        a = ''.join(sim(H['actores'][k][aid]) for k in orden); b = ''.join(sim(D['actores'][k][aid]) for k in orden)
        print(f"{aid:6}{a:{len(orden)+1}}{b:{len(orden)+1}} {i['desc']}{'  ◀ cambia' if a != b else ''}")
    print('```\n')
