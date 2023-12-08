# GitOps with ArgoCD and Gloo Mesh

# Introduction
GitOps is becoming increasingly popular approach to manage Kubernetes components. It works by using Git as a single source of truth for declarative infrastructure and applications, allowing your application definitions, configurations, and environments to be declarative and version controlled. This helps to make these workflows automated, auditable, and easy to understand.

# Purpose of this Tutorial
The intended use case for this blog series is primarily to demonstrate how Gloo Mesh components can be deployed using a GitOps workflow (in this case Argo CD).

In this blog we will walk through the following steps:
- Installing Argo CD
- Installing and configuring Gloo Mesh
- Installing Istio
- Registering your clusters to Gloo Mesh
- Creating a Virtual Mesh across both clusters
- Explore the Gloo Mesh Dashboard

# High Level Architecture
![](https://github.com/ably77/gloo-mesh-argocd-blog/blob/main/images/arch2.png)

# Prerequisites
The tutorial is intended to be demonstrated using three Kubernetes clusters. The instructions have been tested locally on k3d, as well as in EKS and GKE. The scope of this guide does not cover the installation and setup of Kubernetes, and expects users to provide this as a prerequisite. The instructions below expect the cluster contexts to be `mgmt`, `cluster1`, and `cluster2`. An example output below:
```
% kubectl config get-contexts
CURRENT   NAME        CLUSTER          AUTHINFO             NAMESPACE
          cluster1    k3d-cluster1     admin@k3d-cluster1   
          cluster2    k3d-cluster2     admin@k3d-cluster2   
          mgmt        k3d-mgmt         admin@k3d-mgmt       
```

### Installing Argo CD	
Following best practice for gloo-mesh, we will be deploying Argo CD to our `mgmt` cluster, which will then manage our deployments on `cluster1` and `cluster2`

Create the Argo CD namespace in mgmt cluster
```
kubectl create namespace argocd --context mgmt
```

The command below will deploy Argo CD 2.8.0 using the [non-HA YAML manifests](https://github.com/argoproj/argo-cd/releases)
```
until kubectl apply -k https://github.com/solo-io/gitops-library.git/argocd/deploy/default/ --context mgmt > /dev/null 2>&1; do sleep 2; done
```

Check to see argocd status
```
% kubectl get pods -n argocd --context mgmt
NAME                                  READY   STATUS    RESTARTS   AGE
argocd-redis-74d8c6db65-lj5qz         1/1     Running   0          5m48s
argocd-dex-server-5896d988bb-ksk5j    1/1     Running   0          5m48s
argocd-application-controller-0       1/1     Running   0          5m48s
argocd-repo-server-6fd99dbbb5-xr8ld   1/1     Running   0          5m48s
argocd-server-7dd7894bd7-t92rr        1/1     Running   0          5m48s
```

We can also change the password to: `admin / solo.io`:
```
# bcrypt(password)=$2a$10$79yaoOg9dL5MO8pn8hGqtO4xQDejSEVNWAGQR268JHLdrCw6UCYmy
# password: solo.io
kubectl --context mgmt -n argocd patch secret argocd-secret \
  -p '{"stringData": {
    "admin.password": "$2a$10$79yaoOg9dL5MO8pn8hGqtO4xQDejSEVNWAGQR268JHLdrCw6UCYmy",
    "admin.passwordMtime": "'$(date +%FT%T%Z)'"
  }}'
```

### Navigating to Argo CD UI
At this point, we should be able to access our Argo CD server using port-forward at localhost:9999
```
kubectl port-forward svc/argocd-server -n argocd 9999:443 --context mgmt
```

### Login to Argo CD using CLI
```
argocd login localhost:9999
```

### add cluster1 and cluster2 to Argo CD
```
argocd cluster add cluster1
argocd cluster add cluster2
```

Example output below:
```
% argocd cluster add cluster1                                                     
WARNING: This will create a service account `argocd-manager` on the cluster referenced by context `cluster1` with full cluster level admin privileges. Do you want to continue [y/N]? y
INFO[0002] ServiceAccount "argocd-manager" created in namespace "kube-system" 
INFO[0003] ClusterRole "argocd-manager-role" created    
INFO[0003] ClusterRoleBinding "argocd-manager-role-binding" created 
Cluster 'https://34.72.236.239' added

% argocd cluster add cluster2                                                      
WARNING: This will create a service account `argocd-manager` on the cluster referenced by context `cluster2` with full cluster level admin privileges. Do you want to continue [y/N]? y
INFO[0002] ServiceAccount "argocd-manager" created in namespace "kube-system" 
INFO[0003] ClusterRole "argocd-manager-role" created    
INFO[0003] ClusterRoleBinding "argocd-manager-role-binding" created 
Cluster 'https://199.223.234.166' added
```

### set cluster1 and cluster2 variables
These variables will be used in our Argo applications in the `spec.destination.server` parameter in the Argo Application to direct which cluster the app is deployed to
```
cluster1=https://34.72.236.239
cluster2=https://199.223.234.166
```

### Provide Gloo Mesh Enterprise License Key variable
Gloo Mesh Enterprise requires a Trial License Key:
```
GLOO_PLATFORM_LICENSE_KEY=<input_license_key_here>
```

## Installing Gloo Mesh
Gloo Mesh can be installed and configured easily using Helm + Argo CD. To install Gloo Mesh Enterprise 2.4.4 with the default helm values, simply deploy the manifest below

Create the Argo CD namespace in mgmt cluster
```
kubectl create namespace gloo-mesh --context mgmt
```

Then deploy the Gloo Platform helm chart using an Argo Application
```
kubectl apply --context mgmt -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gloo-platform-crds
  namespace: argocd
spec:
  destination:
    namespace: gloo-mesh
    server: https://kubernetes.default.svc
  project: default
  source:
    chart: gloo-platform-crds
    repoURL: https://storage.googleapis.com/gloo-platform/helm-charts
    targetRevision: 2.4.4
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 2
      backoff:
        duration: 5s
        maxDuration: 3m0s
        factor: 2
EOF
```

Then deploy the Gloo Platform helm chart using an Argo Application
```
kubectl apply --context mgmt -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gloo-platform-helm
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    server: https://kubernetes.default.svc
    namespace: gloo-mesh
  project: default
  source:
    chart: gloo-platform
    helm:
      skipCrds: true
      values: |
        licensing:
          licenseKey: ${GLOO_MESH_LICENSE_KEY}
        common:
          cluster: mgmt
        glooMgmtServer:
          enabled: true
          ports:
            healthcheck: 8091
        prometheus:
          enabled: true
        redis:
          deployment:
            enabled: true
        telemetryGateway:
          enabled: true
          service:
            type: LoadBalancer
        glooUi:
          enabled: true
          serviceType: LoadBalancer   
    repoURL: https://storage.googleapis.com/gloo-platform/helm-charts
    targetRevision: 2.4.4
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
  # ignore the self-signed certs that are being generated automatically    
  ignoreDifferences:
  - group: v1
    kind: Secret    
EOF
```

You can check to see that the Gloo Mesh Management Plane is deployed:
```
% kubectl get pods -n gloo-mesh --context mgmt  
NAME                                     READY   STATUS    RESTARTS   AGE
gloo-mesh-redis-788545948f-v94wg         1/1     Running   0          3m37s
gloo-telemetry-gateway-677b9b65f-d6tbn   1/1     Running   0          3m38s
gloo-mesh-mgmt-server-5ddc5f8b6b-6cb8l   1/1     Running   0          3m37s
gloo-mesh-ui-6879b5c9cc-jntqm            3/3     Running   0          3m37s
prometheus-server-6d8c8bc5b9-dlbvv       2/2     Running   0          3m37s
```

## Installing Istio
Here we will use Argo CD to demonstrate how to deploy and manage Istio on `cluster1` and `cluster2`. For our Istio deployment, we will be using the `IstioOperator` to showcase the integration of Argo CD with Operators in addition to Helm. Note that the `spec.destination.server` value is set to our variable `${cluster1}` which is the Kubernetes cluster we are deploying on.

First deploy the Istio base 1.19.3 helm chart to `cluster1`
```
kubectl apply --context mgmt -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-base-cluster1
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  destination:
    server: ${cluster1}
    namespace: istio-system
  project: default
  source:
    chart: base
    repoURL: https://istio-release.storage.googleapis.com/charts
    targetRevision: 1.19.3
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
---
kubectl apply --context mgmt -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-base-cluster2
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  destination:
    server: ${cluster2}
    namespace: istio-system
  project: default
  source:
    chart: base
    repoURL: https://istio-release.storage.googleapis.com/charts
    targetRevision: 1.19.3
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

Now, lets deploy the Istio control plane

First cluster1:
```
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istiod
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    server: ${cluster1}
    namespace: istio-system
  project: default
  source:
    chart: istiod
    repoURL: https://istio-release.storage.googleapis.com/charts
    targetRevision: 1.19.3
    helm:
      values: |
        revision: 1-19
        global:
          meshID: mesh1
          multiCluster:
            clusterName: cluster1
          network: cluster1
          hub: us-docker.pkg.dev/gloo-mesh/istio-workshops
          tag: 1.19.3-solo
        meshConfig:
          trustDomain: cluster1
          accessLogFile: /dev/stdout
          enableAutoMtls: true
          defaultConfig:
            envoyAccessLogService:
              address: gloo-mesh-agent.gloo-mesh:9977
            proxyMetadata:
              ISTIO_META_DNS_CAPTURE: "true"
              ISTIO_META_DNS_AUTO_ALLOCATE: "true"
              GLOO_MESH_CLUSTER_NAME: cluster1
        pilot:
          env:
            PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES: "false"
            PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
  syncPolicy:
    automated: {}
    syncOptions:
      - CreateNamespace=true
  ignoreDifferences:
  - group: '*'
    kind: '*'
    managedFieldsManagers:
    - argocd-application-controller
EOF
```

Next on cluster2:
```
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istiod-cluster2
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    server: ${cluster2}
    namespace: istio-system
  project: default
  source:
    chart: istiod
    repoURL: https://istio-release.storage.googleapis.com/charts
    targetRevision: 1.19.3
    helm:
      values: |
        revision: 1-19
        global:
          meshID: mesh1
          multiCluster:
            clusterName: cluster2
          network: cluster2
          hub: us-docker.pkg.dev/gloo-mesh/istio-workshops
          tag: 1.19.3-solo
        meshConfig:
          trustDomain: cluster2
          accessLogFile: /dev/stdout
          enableAutoMtls: true
          defaultConfig:
            envoyAccessLogService:
              address: gloo-mesh-agent.gloo-mesh:9977
            proxyMetadata:
              ISTIO_META_DNS_CAPTURE: "true"
              ISTIO_META_DNS_AUTO_ALLOCATE: "true"
              GLOO_MESH_CLUSTER_NAME: cluster2
        pilot:
          env:
            PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES: "false"
            PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
  syncPolicy:
    automated: {}
    syncOptions:
      - CreateNamespace=true
  ignoreDifferences:
  - group: '*'
    kind: '*'
    managedFieldsManagers:
    - argocd-application-controller
EOF
```

## Register your clusters to Gloo Mesh with Helm + Argo CD
First we want to create a `KubernetesCluster` resource to represent the remote clusters (`cluster1` and `cluster2`) and store relevant data, such as the remote cluster's local domain. The `metadata.name` of the resource must match the value for `relay.cluster` in the Helm chart, and the `spec.clusterDomain` must match the local cluster domain of the Kubernetes cluster.

First for cluster1
```
kubectl apply --context mgmt -f- <<EOF
apiVersion: multicluster.solo.io/v1alpha1
kind: KubernetesCluster
metadata:
  name: cluster1
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
EOF
```

Then for cluster2
```
kubectl apply --context mgmt -f- <<EOF
apiVersion: multicluster.solo.io/v1alpha1
kind: KubernetesCluster
metadata:
  name: cluster2
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
EOF
```

Since we installed Gloo Mesh by using the default self-signed certificates, you must copy the root CA certificate to a secret in the remote cluster so that the relay agent will trust the TLS certificate from the relay server. You must also copy the bootstrap token used for initial communication to the remote cluster. This token is used only to validate initial communication between the relay agent and server. After the gRPC connection is established, the relay server issues a client certificate to the relay agent to establish a mutually-authenticated TLS session.

You can run the script below to easily do this for you:
```
./config/relay-cert-token.sh
```

Grab External-IP of the enterprise-networking service in the mgmt plane as we will be using this
```
SVC=$(kubectl --context mgmt -n gloo-mesh get svc enterprise-networking -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

Deploy the Gloo Mesh agent (enterprise-agent) on cluster1 using Argo CD
```
kubectl apply --context mgmt -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gm-enterprise-agent-cluster1
  namespace: argocd
spec:
  destination:
    server: ${cluster1}
    namespace: gloo-mesh
  source:
    repoURL: 'https://storage.googleapis.com/gloo-mesh-enterprise/enterprise-agent'
    targetRevision: 2.4.4
    chart: enterprise-agent
    helm:
      valueFiles:
        - values.yaml
      parameters:
        - name: relay.cluster
          value: cluster1
        - name: relay.serverAddress
          value: '${SVC}:9900'
        - name: relay.tokenSecret.namespace
          value: gloo-mesh
        - name: authority
          value: enterprise-networking.gloo-mesh
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
    syncOptions:
    - CreateNamespace=true
    - Replace=true
    - ApplyOutOfSyncOnly=true
  project: default
EOF
```

Deploy enterprise-agent on cluster2 using Argo CD
```
kubectl apply --context mgmt -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gm-enterprise-agent-cluster2
  namespace: argocd
spec:
  destination:
    server: ${cluster2}
    namespace: gloo-mesh
  source:
    repoURL: 'https://storage.googleapis.com/gloo-mesh-enterprise/enterprise-agent'
    targetRevision: 2.4.4
    chart: enterprise-agent
    helm:
      valueFiles:
        - values.yaml
      parameters:
        - name: relay.cluster
          value: cluster2
        - name: relay.serverAddress
          value: '$SVC:9900'
        - name: relay.tokenSecret.namespace
          value: gloo-mesh
        - name: authority
          value: enterprise-networking.gloo-mesh
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
    syncOptions:
    - CreateNamespace=true
    - Replace=true
    - ApplyOutOfSyncOnly=true
  project: default
EOF
```

# Verifying the registration
Verify that the relay agent pod has a status of `Running`
```
kubectl get pods -n gloo-mesh --context cluster1
```

# Verifying the registration using meshctl

First install meshctl if you haven't done so already
```
export GLOO_MESH_VERSION=v2.4.4
curl -sL https://run.solo.io/meshctl/install | sh -
export PATH=$HOME/.gloo-mesh/bin:$PATH
```

Verify that the cluster is successfully identified by the management plane. This check might take a few seconds to ensure that the expected remote relay agent is now running and is connected to the relay server in the management cluster.
```
meshctl check server --kubecontext mgmt
```

Output should look similar to below:
```
% meshctl check server --kubecontext mgmt
Querying cluster. This may take a while.
Gloo Mesh Management Cluster Installation
--------------------------------------------

🟢 Gloo Mesh Pods Status
Forwarding from 127.0.0.1:9091 -> 9091

Forwarding from [::1]:9091 -> 9091

Handling connection for 9091

+----------+------------+-------------------------------+-----------------+
| CLUSTER  | REGISTERED | DASHBOARDS AND AGENTS PULLING | AGENTS PUSHING  |
+----------+------------+-------------------------------+-----------------+
| cluster1 | true       |                             2 |               1 |
+----------+------------+-------------------------------+-----------------+
| cluster2 | true       |                             2 |               1 |
+----------+------------+-------------------------------+-----------------+

🟢 Gloo Mesh Agents Connectivity

Management Configuration
---------------------------

🟢 Gloo Mesh CRD Versions

🟢 Gloo Mesh Networking Configuration Resources
```

# Visualize in Gloo Mesh Dashboard
Access Gloo Mesh Dashboard at `http://localhost:8090`:
```
kubectl port-forward -n gloo-mesh svc/dashboard 8090
```

At this point, you should have Gloo Mesh installed and two clusters with Istio registered to Gloo Mesh!
![](https://github.com/ably77/gloo-mesh-argocd-blog/blob/main/images/gm1.png)

# Deploy and Configure your VirtualMesh
Deploy VirtualMesh to mgmt cluster to unify our two meshes on `cluster1` and `cluster2`
```
kubectl apply --context mgmt -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gloo-mesh-virtualmesh
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/solo-io/gitops-library
    targetRevision: HEAD
    path: gloo-mesh/overlay/virtualmesh/rbac-disabled/
  destination:
    server: https://kubernetes.default.svc
    namespace: gloo-mesh
  syncPolicy:
    automated:
      prune: false # Specifies if resources should be pruned during auto-syncing ( false by default ).
      selfHeal: false # Specifies if partial app sync should be executed when resources are changed only in target Kubernetes cluster and no git change detected ( false by default ).
EOF
```

At this point, if you navigate back to the gloo-mesh dashboard to the Meshes tab we should see that a virtual-mesh has been successfully deployed across our two clusters!
![](https://github.com/ably77/gloo-mesh-argocd-blog/blob/main/images/gm2.png)

# Conclusions and Next Steps
Now that we have deployed all of the necessary infrastructure components for multicluster service mesh, stay tuned for part 2 of this blog series where we will expand upon this base using the bookinfo application to demonstrate advanced traffic routing, policies, and observability across multiple clusters/meshes!