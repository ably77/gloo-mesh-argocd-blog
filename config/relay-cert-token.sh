# create gloo-mesh ns in cluster1 and cluster2
kubectl create ns gloo-mesh --context cluster1
kubectl create ns gloo-mesh --context cluster2

# ensure mgmt certs are in the remote clusters
kubectl get secret relay-root-tls-secret -n gloo-mesh --context mgmt -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
kubectl create secret generic relay-root-tls-secret -n gloo-mesh --context cluster1 --from-file ca.crt=ca.crt
kubectl create secret generic relay-root-tls-secret -n gloo-mesh --context cluster2 --from-file ca.crt=ca.crt
rm ca.crt

# ensure mgmt tokens are in the remote clusters
kubectl get secret relay-identity-token-secret -n gloo-mesh --context mgmt -o jsonpath='{.data.token}' | base64 -d > token
kubectl create secret generic relay-identity-token-secret -n gloo-mesh --context cluster1 --from-file token=token
kubectl create secret generic relay-identity-token-secret -n gloo-mesh --context cluster2 --from-file token=token
rm token