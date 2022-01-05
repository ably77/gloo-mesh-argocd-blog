# GitOps with ArgoCD and Gloo Mesh (part 1)

# Introduction
GitOps is becoming increasingly popular approach to manage Kubernetes components. It works by using Git as a single source of truth for declarative infrastructure and applications, allowing your application definitions, configurations, and environments to be declarative and version controlled. This helps to make these workflows automated, auditable, and easy to understand. 

# Purpose of this Tutorial
The intended use case for part 1 of this blog series is primarily to demonstrate how Gloo Mesh components can be deployed using a GitOps workflow (in this case Argo CD).

In this blog we will walk through the following steps:
- Installing Argo CD
- Installing and configuring Gloo Mesh
- Installing Istio
- Registering your clusters to Gloo Mesh
- Creating a Virtual Mesh across both clusters
- Explore the Gloo Mesh Dashboard

# Prerequisites
The tutorial is intended to be demonstrated using three Kubernetes clusters. The instructions have been tested locally on k3d + MetalLB setup as well as in EKS and GKE. The scope of this guide does not cover the installation and setup of Kubernetes, and expects users to provide this as a prerequisite. The instructions below expect the cluster contexts to be `mgmt`, `cluster1`, and `cluster2`. An example output below:
```
% kubectl config get-contexts
CURRENT   NAME        CLUSTER          AUTHINFO             NAMESPACE
          cluster1    k3d-cluster1     admin@k3d-cluster1   
          cluster2    k3d-cluster2     admin@k3d-cluster2   
          mgmt        k3d-mgmt         admin@k3d-mgmt       
```

## Installing argocd
While in Argo CD it is possible for a single Argo CD instance to manage deployments across multiple clusters, for simplicity we will be deploying Argo CD to each cluster separately.

Create the `argocd` namespace in each cluster
```
kubectl create namespace argocd --context mgmt
kubectl create namespace argocd --context cluster1
kubectl create namespace argocd --context cluster2
```

The command below will deploy Argo CD 2.1.7 using the [non-HA YAML manifests](https://github.com/argoproj/argo-cd/releases)
```
until kubectl apply -k https://github.com/solo-io/gitops-library.git/argocd/overlay/default/ --context mgmt; do sleep 2; done
until kubectl apply -k https://github.com/solo-io/gitops-library.git/argocd/overlay/default/ --context cluster1; do sleep 2; done
until kubectl apply -k https://github.com/solo-io/gitops-library.git/argocd/overlay/default/ --context cluster2; do sleep 2; done
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

We can also change the password to: `admin / solo.io` on all three clusters:
```
# bcrypt(password)=$2a$10$79yaoOg9dL5MO8pn8hGqtO4xQDejSEVNWAGQR268JHLdrCw6UCYmy
# password: solo.io
kubectl --context ${CONTEXT} -n argocd patch secret argocd-secret \
  -p '{"stringData": {
    "admin.password": "$2a$10$79yaoOg9dL5MO8pn8hGqtO4xQDejSEVNWAGQR268JHLdrCw6UCYmy",
    "admin.passwordMtime": "'$(date +%FT%T%Z)'"
  }}'
```

## Navigating to Argo CD UI
At this point, we should be able to access our Argo CD server using port-forward at localhost:8080. Dont forget to input the context you want to view
```
kubectl port-forward svc/argocd-server -n argocd 8080:443 --context <CONTEXT>
```

## Installing Gloo Mesh Management Plane
Gloo Mesh can be installed and configured easily using Helm + Argo CD. To install Gloo Mesh Enterprise 1.2.1 with the default helm values, simply add in your license key to the YAML below and deploy away! 

Note, the Gloo Mesh Management Plane is recommended to be in it's own `mgmt` cluster - but this is not a strict requirement.
```
kubectl apply --context mgmt -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gloo-mesh-enterprise-helm
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    server: https://kubernetes.default.svc
    namespace: gloo-mesh
  project: default
  source:
    chart: gloo-mesh-enterprise
    helm:
      values: |
        licenseKey: $LICENSE_KEY
    repoURL: https://storage.googleapis.com/gloo-mesh-enterprise/gloo-mesh-enterprise
    targetRevision: 1.2.1
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true 
EOF
```

You can check to see that the gloo mesh management plane is deployed:
```
% kubectl get pods -n gloo-mesh --context mgmt   
NAME                                     READY   STATUS    RESTARTS   AGE
svclb-enterprise-networking-qxkc8        1/1     Running   0          63s
redis-dashboard-66556bf4db-8t54q         1/1     Running   0          63s
enterprise-networking-75fbb69b74-xhjqp   1/1     Running   0          63s
dashboard-c4cf86495-hbxtg                3/3     Running   0          63s
prometheus-server-5bc557db5f-mp62j       2/2     Running   0          63s
```

## Installing Istio
Here we will use Argo CD to demonstrate how to deploy and manage Istio on `cluster1` and `cluster2`. For our Istio deployment, we will be using the `IstioOperator` to showcase the integration of Argo CD with Operators in addition to Helm.

First deploy the Istio Operator v1.11.4 to `cluster1`
```
kubectl apply --context cluster1 -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-operator-helm
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-operator
  project: default
  source:
    repoURL: https://github.com/istio/istio.git
    path: manifests/charts/istio-operator
    targetRevision: 1.11.4
    helm:
      parameters:
        - name: "hub"
          value: "docker.io/istio"
        - name: "tag"
          value: "1.11.4"
        - name: "operatorNamespace"
          value: "istio-operator"
        - name: "istioNamespace"
          value: "istio-system"
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
  ignoreDifferences:
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
      jsonPointers:
        - /metadata/labels
        - /spec/names/shortNames
EOF
```

And next to `cluster2`
```
kubectl apply --context cluster2 -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-operator-helm
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-operator
  project: default
  source:
    repoURL: https://github.com/istio/istio.git
    path: manifests/charts/istio-operator
    targetRevision: 1.11.4
    helm:
      parameters:
        - name: "hub"
          value: "docker.io/istio"
        - name: "tag"
          value: "1.11.4"
        - name: "operatorNamespace"
          value: "istio-operator"
        - name: "istioNamespace"
          value: "istio-system"
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
  ignoreDifferences:
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
      jsonPointers:
        - /metadata/labels
        - /spec/names/shortNames
EOF
```

You can check to see that the Istio Operator is deployed:
```
% kubectl get pods -n istio-operator --context cluster1
NAME                              READY   STATUS    RESTARTS   AGE
istio-operator-6f9dcd4469-hgsl9   1/1     Running   0          71s
```

Now, lets deploy Istio 1.11.4

First cluster1:
```
kubectl apply --context cluster1 -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gm-istio-workshop-cluster1-1-11-4
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/solo-io/gitops-library
    targetRevision: HEAD
    path: istio/overlay/1-11-4/gm-istio-profiles/workshop/cluster1/
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
EOF
```

Next on cluster2:
```
kubectl apply --context cluster2 -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gm-istio-workshop-cluster2-1-11-4
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/solo-io/gitops-library
    targetRevision: HEAD
    path: istio/overlay/1-11-4/gm-istio-profiles/workshop/cluster2/
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
EOF
```

For those who are curious, the Istio profile being deployed by Argo CD at the `path: istio/overlay/1-11-4/gm-istio-profiles/workshop/cluster1/` is the one used for our Gloo Mesh workshops based on the `default` Istio profile:
```
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-default-profile
  namespace: istio-system
spec:
  components:
    ingressGateways:
    - enabled: true
      k8s:
        env:
        - name: ISTIO_META_ROUTER_MODE
          value: sni-dnat
        - name: ISTIO_META_REQUESTED_NETWORK_VIEW
          value: network1
        service:
          ports:
          - name: http2
            port: 80
            targetPort: 8080
          - name: https
            port: 443
            targetPort: 8443
          - name: tcp-status-port
            port: 15021
            targetPort: 15021
          - name: tls
            port: 15443
            targetPort: 15443
          - name: tcp-istiod
            port: 15012
            targetPort: 15012
          - name: tcp-webhook
            port: 15017
            targetPort: 15017
      label:
        topology.istio.io/network: network1
      name: istio-ingressgateway
    pilot:
      k8s:
        env:
        - name: PILOT_SKIP_VALIDATE_TRUST_DOMAIN
          value: "true"
  hub: gcr.io/istio-enterprise
  meshConfig:
    accessLogFile: /dev/stdout
    defaultConfig:
      envoyAccessLogService:
        address: enterprise-agent.gloo-mesh:9977
      envoyMetricsService:
        address: enterprise-agent.gloo-mesh:9977
      proxyMetadata:
        GLOO_MESH_CLUSTER_NAME: cluster1
        ISTIO_META_DNS_AUTO_ALLOCATE: "true"
        ISTIO_META_DNS_CAPTURE: "true"
    enableAutoMtls: true
    trustDomain: cluster1
  profile: default
  tag: 1.11.4
  values:
    global:
      meshID: mesh1
      meshNetworks:
        network1:
          endpoints:
          - fromRegistry: cluster1
          gateways:
          - port: 443
            registryServiceName: istio-ingressgateway.istio-system.svc.cluster.local
      multiCluster:
        clusterName: cluster1
      network: network1
```

Check to see that Istio has been deployed
```
% kubectl get pods -n istio-system --context cluster1
NAME                                    READY   STATUS    RESTARTS   AGE
istiod-869d56698-54hzf                  1/1     Running   0          100s
istio-ingressgateway-7cf4cd6fc6-trt9h   1/1     Running   0          70s
```

## Enforce mTLS in our Istio Deployments
The Istio default install sets mTLS to `PERMISSIVE` mode. Let's enforce `STRICT` mode instead

For cluster1:
```
kubectl apply --context cluster1 -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: strict-mtls
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/solo-io/gitops-library
    targetRevision: HEAD
    path: istio/overlay/mtls/strict/
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
EOF
```

For cluster2
```
kubectl apply --context cluster2 -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: strict-mtls
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/solo-io/gitops-library
    targetRevision: HEAD
    path: istio/overlay/mtls/strict/
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
EOF
```

## Register your clusters to Gloo Mesh with Helm + argocd
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
kubectl apply --context cluster1 -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gm-enterprise-agent-cluster1
  namespace: argocd
spec:
  destination:
    server: https://kubernetes.default.svc
    namespace: gloo-mesh
  source:
    repoURL: 'https://storage.googleapis.com/gloo-mesh-enterprise/enterprise-agent'
    targetRevision: 1.2.1
    chart: enterprise-agent
    helm:
      valueFiles:
        - values.yaml
      parameters:
        - name: relay.cluster
          value: cluster1
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

Deploy enterprise-agent on cluster2 using Argo CD
```
kubectl apply --context cluster2 -f- <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gm-enterprise-agent-cluster2
  namespace: argocd
spec:
  destination:
    server: https://kubernetes.default.svc
    namespace: gloo-mesh
  source:
    repoURL: 'https://storage.googleapis.com/gloo-mesh-enterprise/enterprise-agent'
    targetRevision: 1.2.1
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

## Visualize in Gloo Mesh Dashboard
Access the Gloo Mesh Dashboard at `http://localhost:8090`:
```
kubectl port-forward -n gloo-mesh svc/dashboard 8090
```

At this point, you should have Gloo Mesh installed and two clusters with Istio registered to Gloo Mesh!
![](https://github.com/ably77/gloo-mesh-argocd-blog/blob/main/images/gm1.png)

## Deploy and Configure your VirtualMesh
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
