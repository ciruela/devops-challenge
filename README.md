# Kubernetes Deployment Strategies — Blue/Green & Canary (Local)

Resumen
-------
Este repositorio contiene una implementación de ejemplo para demostrar estrategias de despliegue: Blue/Green y Canary, pensado para ejecutarse en un entorno Kubernetes local (kind / minikube). Incluye micro-servicios simples, Dockerfiles, manifests de Kubernetes, scripts de carga (k6) y utilidades para correr todo localmente y en CI.

Estructura del repo (resumen)
-----------------------------
- `apps/`
  - `blue-v1/` — servicio "blue" (app Flask)
  - `blue-v2/` — servicio "green" (app Flask)
  - `canary/` — servicio canary (si existe)
  - `requirements.txt` — dependencias Python usadas por los Dockerfiles
- `k8s/`
  - `blue-green/` — deployments y service para blue/green
  - `canary/` — manifiestos para canary
  - `load-test/` — ConfigMap con scripts k6 y Jobs que correrían k6 en-cluster
- `scripts/`
  - `ci-local.sh` — runner local que replica el flujo de CI (build → kind → load images → apply manifests → run k6 via docker + port-forward)
  - `k6/` — Dockerfile para construir imagen k6 hermética (opcional)
- `artifacts/` — (generado) contiene scripts extraídos y resultados JSON/logs de k6
- `.github/workflows/ci.yml` — pipeline CI para GitHub Actions (con kind + k6 jobs + Trivy)

Requisitos (local)
------------------
- Docker Desktop (o Docker Engine) instalado y funcionando
- kind (https://kind.sigs.k8s.io) o minikube (si prefieres)
- kubectl configurado
- jq (para parsear configmaps)
- (Opcional) k6 local si prefieres correrlo fuera de Docker
- En macOS: `host.docker.internal` se usa para que contenedores Docker alcancen puertos del host; en Linux necesitarás adaptar (ver Troubleshooting).

Resumen del flujo automatizado local
-----------------------------------
El script `scripts/ci-local.sh` automatiza:
1. Construir imágenes Docker para `blue`, `green` y `canary`.
2. Construir imagen `local/k6:ci` para ejecutar k6.
3. Crear (o reutilizar) un cluster `kind` llamado `ci`.
4. Cargar las imágenes en el cluster (kind load).
5. Aplicar manifiestos K8s de `k8s/blue-green`, `k8s/canary` y el ConfigMap de `k8s/load-test`.
6. Esperar a que los pods estén listos.
7. Extraer los scripts k6 desde el ConfigMap, reescribir las URLs para apuntar a `host.docker.internal` (para ejecutar k6 en un contenedor Docker local usando `kubectl port-forward`) y ejecutar k6.
8. Guardar artifacts (`artifacts/k6-bluegreen.json`, `artifacts/k6-canary.json`) y logs.

Cómo ejecutar el flujo automatizado (rápido)
-------------------------------------------
1. Desde la raíz del repo:
```bash
# dar permiso si es necesario
chmod +x ./scripts/ci-local.sh

# ejecutar (recomendado en macOS / Linux con Docker)
./scripts/ci-local.sh
```

Salida:
- Verás logs por consola (docker build, kind, kubectl apply, k6 progress).
- Al finalizar, artifacts en `./artifacts/` con JSON y logs de k6.

Comandos útiles:
```bash
ls -lh artifacts
less artifacts/k6-bluegreen.log
head -n 40 artifacts/k6-bluegreen.json
kind delete cluster --name ci   # para limpiar
```

Instrucciones manuales paso a paso
---------------------------------

Uso `kind` en los ejemplos; si prefieres `minikube` los comandos de cluster y de carga de imágenes cambian ligeramente.

1) Crear cluster (kind)
```bash
# instalar kind si no lo tienes
# https://kind.sigs.k8s.io/docs/user/quick-start/#installation

kind create cluster --name ci
kubectl cluster-info --context kind-ci
```

2) Construir imágenes Docker
```bash
# desde la raíz del repo
docker build -t content-blue:local -f apps/blue-v1/Dockerfile apps/blue-v1
docker build -t content-green:local -f apps/blue-v2/Dockerfile apps/blue-v2
# si existe:
docker build -t content-canary:local -f apps/canary/Dockerfile apps/canary

# construir imagen k6 para correr en contenedor (opcional)
docker build -t local/k6:ci -f scripts/k6/Dockerfile scripts/k6
```

3) Cargar imágenes en kind 
```bash
kind load docker-image content-blue:local --name ci
kind load docker-image content-green:local --name ci
kind load docker-image content-canary:local --name ci
kind load docker-image local/k6:ci --name ci
```

4) Aplicar manifests de Kubernetes
```bash
kubectl apply -f k8s/blue-green
kubectl apply -f k8s/canary
# el ConfigMap con scripts k6
kubectl apply -f k8s/load-test/configmap-k6.yaml
```

5) Verificar que los pods estén listos
```bash
kubectl get pods -l app=content -o wide
kubectl wait --for=condition=ready pod -l app=content --timeout=120s
```

6) Probar endpoints (verificación básica)
- Identifica el Service: en `k8s/blue-green/service.yaml` suele haber un Service que expone `app=content`.
- Puedes usar `kubectl port-forward` para exponer el service en localhost:

```bash
# suponer service name: content-service (revisá en k8s/blue-green/service.yaml)
kubectl port-forward svc/content-service 8080:80 &
PF_PID=$!

# probar endpoints
curl -sS http://localhost:8080/ | jq
curl -sS http://localhost:8080/healthz

# al terminar
kill $PF_PID
```

Salida esperada (ejemplo):
- `GET /` → JSON con fields: `service`, `version`, `color`, `message` (HTTP 200).
- `GET /healthz` → `{"status":"ok"}` (HTTP 200).

7) Ejecutar k6 manualmente (sin usar jobs in-cluster)
Opciones:
- Ejecutar k6 desde tu host (si tienes k6 instalado).
- Ejecutar k6 dentro de la imagen `local/k6:ci` y montar la carpeta de scripts.

a) Extraer script k6 desde ConfigMap:
```bash
kubectl get configmap k6-scripts -o json | jq -r '.data["blue-green.js"]' > artifacts/blue-green.js
kubectl get configmap k6-scripts -o json | jq -r '.data["canary.js"]' > artifacts/canary.js
```

b) Port-forward servicio y ejecutar k6 (ejemplo para blue/green):
```bash
kubectl port-forward svc/content-service 8080:80 &
PF_PID=$!

# si usas docker k6 image (recomendado para consistencia)
docker run --rm -v "$(pwd)/artifacts":/scripts local/k6:ci run --out json=/tmp/k6-bluegreen.json /scripts/blue-green.js

# copiar resultado desde el contenedor (si lo montaste en /tmp)
# si montaste artifacts a /tmp en el contenedor, el archivo estará en $(pwd)/artifacts
kill $PF_PID
```

Nota importante (macOS vs Linux):
- En macOS, cuando ejecutas k6 dentro de un contenedor Docker y quieres que el contenedor alcance `localhost` del host, debes usar `host.docker.internal` en la URL de destino (o exponer puertos al host y usar esa IP). El script automatizado ya reemplaza las URLs para ese caso. En Linux `host.docker.internal` no está disponible por defecto — en Linux puedes ejecutar k6 en tu host directamente o ajustar la red de Docker (por ejemplo `--network host`, con precauciones).

Cómo validar Blue/Green y Canary manualmente
-------------------------------------------
- Blue/Green:
  1. Despliega `blue-v1` y `blue-v2` (deployments) y un único Service que inicialmente apunta al Deployment `blue`.
  2. Para "switch" a green, actualiza el selector del Service o actualiza etiquetas de pods para rotar el tráfico al deployment `green`.
  3. Verifica con requests y logs que la respuesta cambia (campo `color` o `version`).

- Canary:
  1. Crea un deployment estable (stable) y despliega el canary con réplicas pequeñas (por ejemplo 1).
  2. Usa Service/Ingress y tráfico dividido (80% stable / 20% canary) o pondera tráfico instruyendo un proxy (istio/linkerd) o mediante HPA + kube-proxy manipulations en pruebas controladas.
  3. Ejecuta k6 dirigidas al servicio y compara métricas (latencia, errores) entre las variantes.

Troubleshooting rápido
----------------------
- k6 timeouts / Request Failed:
  - Revisá que `kubectl port-forward` esté corriendo y que la URL en el script k6 apunte a `host.docker.internal:PORT` si corres k6 en contenedor Docker en macOS.
  - Mirá `artifacts/*.log` y la salida completa de k6.
- `kind load docker-image` falla:
  - Asegurate que la imagen existe localmente con `docker images`.
  - Re-construí la imagen con el tag exacto utilizado.
- No se generan JSON de k6:
  - Verifica la línea de ejecución de k6 y los volúmenes montados (dónde se escribe `/tmp/…`).
  - Para jobs in-cluster: si el pod Job termina, `kubectl cp` podría no funcionar; usa logs o escribe a un PVC para persistir resultados.
- Problemas de DNS desde contenedores:
  - En macOS usa `host.docker.internal`. En Linux considera `--network host` o correr k6 en host.

Qué guarda el script y dónde mirar
---------------------------------
- Scripts k6 extraídos: `artifacts/blue-green.js`, `artifacts/canary.js`
- Resultados JSON: `artifacts/k6-bluegreen.json`, `artifacts/k6-canary.json`
- Logs k6 / job logs: `artifacts/k6-bluegreen.log`, `artifacts/k6-canary.log`

CI en GitHub Actions
--------------------
- `.github/workflows/ci.yml` reproduce el flujo: crea cluster kind en runner, build images, carga en kind, aplica manifests, corre jobs k6 (modificados para escribir JSON) y sube artifacts.



