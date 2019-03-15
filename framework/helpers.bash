#!/usr/bin/env bash

# Root directory of integration tests.

if [[ $(uname -s) == 'Darwin' ]]; then
  INTEGRATION_ROOT=$(dirname "$(greadlink -f "$BASH_SOURCE")")
else
  INTEGRATION_ROOT=$(dirname "$(readlink -f "$BASH_SOURCE")")
fi

# Test data path.
TESTDATA="${INTEGRATION_ROOT}/testdata"

# The test image
TEST_IMAGE=${TEST_IMAGE:-"nginx:1.14.2-alpine"}

# The test curl image
TEST_COMMAND_IMAGE=${TEST_COMMAND_IMAGE:-"ibmcom/curl:3.6"}

# The test namespace
NAMESPACE=${NAMESPACE:-ivt}

# Set Skip NAMESPACE creat which used for DEBUG
SKIP_NAMESPACE_CREATE=${SKIP:-false}

# The Cluster Name
CLUSTERNAME=${CLUSTERNAME:-mycluster}

# KUBECTL localtion
KUBECTL=$(which kubectl)

# ROUTER https port
ROUTER_HTTPS_PORT=${ROUTER_HTTPS_PORT:-8443}

# Use to check if the test running in docker
IN_DOCKER=${IN_DOCKER:-false}

# WAIT Timeout
TIMEOUT=20

function client_versions() {
  minor=$($KUBECTL version --client -o yaml | grep minor | awk -F ':' '{print $2}')
  if [[ $minor == "7" ]]; then
      ignor_version=1.8
  else
      ignor_version=1.7
  fi
}

function set_versions() {
  # This function will set some globally available version definitions
  # Can be run after $KUBECTL is populated and kubectl is authenticated

  local versions=$($KUBECTL version --output=json)

  # Kubernetes Server Versions
  export K8S_SERVERVERSION_MAJOR=$(echo $versions | jq -r .serverVersion.major )
  export K8S_SERVERVERSION_MINOR=$(echo $versions | jq -r .serverVersion.minor )
  export K8S_SERVERVERSION_STR=$(echo $versions | jq -r .serverVersion.gitVersion )

  # Kubectl client version
  export K8S_CLIENTVERSION_MAJOR=$(echo $versions | jq -r .clientVersion.major )
  export K8S_CLIENTVERSION_MINOR=$(echo $versions | jq -r .clientVersion.minor )
  export K8S_CLIENTVERSION_STR=$(echo $versions | jq -r .clientVersion.gitVersion )

  # Attempt to detect ICP Version

  ## At least since 3.1.0 ICP version has been set in platform-ui env variables
  local icp_version=$($KUBECTL -n kube-system  describe daemonset platform-ui | grep ICP_VERSION | awk '{ print $2 }')
  if [[ ! -z icp_version && $icp_version != latest ]]; then
    # Attempt to break apart the version number
    export ICPVERSION_MAJOR=$(echo $icp_version | cut -d. -f1)
    export ICPVERSION_MINOR=$(echo $icp_version | cut -d. -f2)
    export ICPVERSION_PATCH=$(echo $icp_version | cut -d. -f3)
    export ICPVERSION_REV=$(echo $icp_version | cut -d. -f4)
  fi
  export ICPVERSION_STR=$icp_version

  # cloudctl can also work
  #cloudctl version
  # Client Version: 3.1.2-dev+d7f5a8646c8d63d2584095804f8d3ef9748b320c
  # Server Version: 3.1.1-973+c18caee2d82dc45146f843cb82ae7d5c28da7bc7

}

# Join an array with a given separator.
function join() {
    local IFS="$1"
    shift
    echo "$*"
}

# Retry a command $1 times until it succeeds. Wait $2 seconds between retries.
function retry() {
    local attempts=$1
    shift
    local delay=$1
    shift
    local i

    for ((i=0; i < attempts; i++)); do
        run "$@"
        if [[ "$status" -eq 0 ]] ; then
            return 0
        fi
        sleep $delay
    done

    echo "Command \"$@\" failed $attempts times. Output: $output"
    false
}

function get_num_master() {

   #Get master node number to handle HA cases
   node_number=$($KUBECTL get node -lrole=master --no-headers | wc -l | sed 's/^ *//')

}

function get_infrastructure_platform() {

  # Attempt to detect what infrastructure platform the cluster is running on
  local provider=""

  # Cloud platforms such as azure, gce, aws and openstack that have cloud providers will
  # set the providerID spec on nodes. Attempt to extract this
  providerstring=$($KUBECTL get nodes -o jsonpath='{.items[0].spec.providerID}')
  if [[ ! -z ${providerstring} ]]; then
    provider=${providerstring%%:*}
  fi

  # TODO
  # There may be other ways to detect other platform
  echo ${provider}
}

function start_kubelet() {
    service kubelet status
    if [[ $? -eq 0 ]]; then
       echo "The kubelet service has been started"
    else
       service kubelet start
    fi
}

function prepare_kubectl() {
  get_arch
  if [[ $IN_DOCKER == "true" ]]; then
      if [[ $arch == x86_64 ]]; then
          if [[ $(uname -s) == 'Darwin' ]]; then
             curl -kLo kubectl https://icp-management-ingress.kube-system:$ROUTER_HTTPS_PORT/api/cli/kubectl-darwin-amd64
           else
             curl -kLo kubectl https://icp-management-ingress.kube-system:$ROUTER_HTTPS_PORT/api/cli/kubectl-linux-amd64
          fi
      elif [[ $arch == ppc64le ]]; then
        curl -kLo kubectl https://icp-management-ingress.kube-system:$ROUTER_HTTPS_PORT/api/cli/kubectl-linux-ppc64le
      else
        curl -kLo kubectl https://icp-management-ingress.kube-system:$ROUTER_HTTPS_PORT/api/cli/kubectl-linux-s390x
      fi
      chmod 755 ./kubectl
      sudo cp ./kubectl /usr/local/bin/kubectl
      export KUBECTL=/usr/local/bin/kubectl

  elif [[ -z $KUBECTL || ! -x $KUBECTL ]]; then
    if [[ ! -z $ACCESS_IP && ! -z $ROUTER_HTTPS_PORT ]]; then
      if [[ $arch == x86_64 ]]; then
        if [[ $(uname -s) == 'Darwin' ]]; then
          curl -kLo kubectl https://$ACCESS_IP:$ROUTER_HTTPS_PORT/api/cli/kubectl-darwin-amd64
        else
          curl -kLo kubectl https://$ACCESS_IP:$ROUTER_HTTPS_PORT/api/cli/kubectl-linux-amd64
        fi
      elif [[ $arch == ppc64le ]]; then
        curl -kLo kubectl https://$ACCESS_IP:$ROUTER_HTTPS_PORT/api/cli/kubectl-linux-ppc64le
      else
        curl -kLo kubectl https://$ACCESS_IP:$ROUTER_HTTPS_PORT/api/cli/kubectl-linux-s390x
      fi
      chmod 755 ./kubectl
      sudo cp ./kubectl /usr/local/bin/kubectl
      export KUBECTL=/usr/local/bin/kubectl
    else 
      echo "Can not find the kubectl in your host, please install the kubectl or set the environment variable ACCESS_IP and ROUTER_HTTPS_PORT."
      exit 1
    fi
  fi
}


function set_kubeclient() {
  $KUBECTL config set-cluster ${CLUSTERNAME} --server=https://$ACCESS_IP:$KUBE_APISERVER_PORT --insecure-skip-tls-verify=true
  $KUBECTL config set-context ${CLUSTERNAME}-icp-context --cluster=$CLUSTERNAME
  $KUBECTL config set-credentials $USERNAME --token=$token
  $KUBECTL config set-context ${CLUSTERNAME}-icp-context --user=$USERNAME --namespace=default
  $KUBECTL config use-context ${CLUSTERNAME}-icp-context
}


# Creates the given Namespace
function create_namespace() {
  ns=${1}
  if [[ $SKIP_NAMESPACE_CREATE == false ]]; then
    #need to first check if the namespace exist or not
    _num_namespace=$($KUBECTL get namespace ${ns} --ignore-not-found | wc -l | sed 's/^ *//')
    if [[ $_num_namespace -eq '0' ]]; then
      $KUBECTL create namespace ${ns}
      for t in $(seq 1 50)
      do
          namespace_status=$($KUBECTL get namespace ${ns} -o jsonpath={.status.phase})
          if [[ $namespace_status == Active ]]; then
              echo "The namespace ${ns} is created"
              echo "Start to create the image policy for namespace ${ns}"
              break
          fi
          sleep 5
      done
    fi
    create_imagepolicy ${ns}
  fi
}

function clean_up() {
    if [[ $SKIP_NAMESPACE_CREATE == false ]]; then
        namespace=$($KUBECTL get namespaces $NAMESPACE --ignore-not-found --no-headers | wc -l | sed 's/^ *//')
        if [[ $namespace -ne 0 ]]; then
            $KUBECTL delete namespaces $NAMESPACE
            while :; do
                num_namespace=$($KUBECTL get namespaces $NAMESPACE --ignore-not-found --no-headers | wc -l | sed 's/^ *//')
                if [[ $num_namespace -eq 0 ]]; then
                    break
                fi
            done
        fi
    fi
}

function get_version() {
    VERSION="latest"
    if [[ -e /opt/ibm/cfc/version ]]; then
        VERSION=$(cat /opt/ibm/cfc/version)
    fi
}

function get_accessip() {
  if [[ $IN_DOCKER == "true" ]]; then
     echo "Run in docker mode, get ACCESS_IP from docker"
     ACCESS_IP=$($KUBECTL -n kube-public get configmap ibmcloud-cluster-info -o yaml |grep cluster_address |head -n 1 | awk -F ':' '{print $2}' )
  else
    echo "Get ACCESS_IP"
    if [[ -z $ACCESS_IP ]]; then
        API_SERVER_ADDRESS=$($KUBECTL config view | grep server | awk -F ':' '{print $3}' | awk -F '/' '{print $3}' | awk  'NR==1{print}')
        if [[ x${API_SERVER_ADDRESS} == 'x' ]]; then
            if [[ -s /etc/cfc/kubelet/kubelet-config ]]; then
                API_SERVER_ADDRESS=$(cat /etc/cfc/kubelet/kubelet-config  | grep https | awk -F ':' '{print $3}'| cut -d "/" -f 3-)
            else
                echo 'Did not found the apiserver access IP address, you can set the environment variable ACCESS_IP and then retry'
                exit 1
            fi
        fi
        ACCESS_IP=${API_SERVER_ADDRESS}
    fi
  fi
}

function create_imagepolicy() {
    ns=${1}
    get_version
    if [[ $VERSION =~ "2.1" ]]; then
        echo "Do not create image policy"
    else
      #TODO, first add sed to handle the macOS wc output, will try to use aother method later
        image_crd=$($KUBECTL get crd imagepolicies.securityenforcement.admission.cloud.ibm.com --no-headers --ignore-not-found | wc -l | sed 's/^ *//')
        if [[ $image_crd == 1 ]]; then
            $KUBECTL apply -f $sert_bats_workdir/imagepolicy.yaml -n ${ns}
        fi
    fi
}

# Creates the given Namespace and make it privileged
function create_privileged_namespace() {
  ns=${1}
  create_namespace ${ns}

  echo "Checking the rolebinding"
  if [[ $($KUBECTL get rolebinding privileged-psp-user -n $ns --no-headers --ignore-not-found | wc -l | sed 's/^ *//') -eq 0 ]]; then
    # Create rolebinding
    echo "Creating the rolebinding"

    if [[ ! -z ${ICPVERSION_STR} && ${ICPVERSION_STR} != latest ]]; then
      # Detect role to use from ICP version
      if [[ ${ICPVERSION_MAJOR} -ge 3 && ${ICPVERSION_MINOR} -ge 1 && ${ICPVERSION_PATCH} -ge 0 ]]; then
        # ICP 3.1.0 and newer has ibm-privileged-clusterrole
        $KUBECTL create rolebinding  privileged-psp-user  --clusterrole=ibm-privileged-clusterrole --serviceaccount=${ns}:default -n ${ns}
      else
        $KUBECTL create rolebinding  privileged-psp-user  --clusterrole=privileged --serviceaccount=${ns}:default -n ${ns}
      fi
    # If we don't know the ICP version, attempt to guess from kubernetes server version
  elif [[ ${ICPVERSION_STR} == latest ]]; then
    $KUBECTL create rolebinding  privileged-psp-user  --clusterrole=ibm-privileged-clusterrole --serviceaccount=${ns}:default -n ${ns}
  else
      # Attempt to detect from kubernetes version
      if [[ ${K8S_SERVERVERSION_MAJOR} -eq 1 && ${K8S_SERVERVERSION_MINOR} -ge 11 ]]; then
        $KUBECTL create rolebinding  privileged-psp-user  --clusterrole=privileged --serviceaccount=${ns}:default -n ${ns}
      else
        $KUBECTL create rolebinding  privileged-psp-user  --clusterrole=ibm-privileged-clusterrole --serviceaccount=${ns}:default -n ${ns}
      fi
    fi
  fi
}

function base64_command() {
  if [[ $(uname -s) == 'Darwin' ]]; then
    _base64_command="base64 -D"
  else
    _base64_command="base64 -d"
  fi
}
# Delete the given Namespace
function delete_namespace() {
  echo "deleting namespace ${1}"
  $KUBECTL delete namespace ${1} --ignore-not-found
}

# Delete the role binding and the given Namespace
function delete_privileged_namespace() {
  ns=${1}
  echo "deleting the rolebinding"
  delete_role_binding privileged-psp-user ${ns}
  delete_namespace ${ns}
}

function delete_role_binding() {
  rb=${1}
  ns=${2}
  echo "deleting the rolebinding"
  $KUBECTL delete rolebinding ${1} -n ${ns} --ignore-not-found
}

function delete_cluster_role_binding() {
  crb=${1}
  echo "deleting the cluster rolebinding"
  $KUBECTL delete clusterrolebinding ${1} --ignore-not-found
}

# Check the pod status for the given deployment
function deployment_pod_status() {
  ds_name=$1
  ns=$2
  num_podrunning=0
  desired_pod=$($KUBECTL get deploy ${ds_name} -n ${ns} -ojsonpath={.spec.replicas})
  for t in $(seq 1 5)
  do
    num_podrunning=$($KUBECTL get deploy ${ds_name} -n ${ns} -ojsonpath={.status.readyReplicas})
    if [[ $num_podrunning == $desired_pod ]]; then
      echo "All the desired pod for deployment ${ds_name} is in running state"
      break
    fi
    echo "Desired pod: $desired_pod  Running pod: $num_podrunning"
    echo "Sleeping for 5 seconds"
    sleep 5
  done
}

# Check the pod status for the given pod
function pod_status() {
  pod_name=$1
  ns=$2
  num_podrunning=0
  desired_pod=$($KUBECTL get pods ${pod_name} -n ${ns}  --no-headers | awk '{print $2}' | awk -F '/' '{print $2}')
  for t in $(seq 1 50)
  do
    num_podrunning=$($KUBECTL get pods ${pod_name} -n ${ns} --no-headers | awk '{print $2}' | awk -F '/' '{print $1}')
    if [[ $num_podrunning == $desired_pod ]]; then
      echo "The pod is in running state"
      break
    fi
    echo "Pod is not ready, Sleeping for 5 seconds"
    sleep 5
  done
}

function get_proxy_ip() {
    proxy_ip=$(ping -c 1 $($KUBECTL get cm ibmcloud-cluster-info -n kube-public -o yaml | grep proxy_address: | awk -F ': ' '{print $2}') |awk -F'[()]' '{print $2;exit}')
}

function get_master_ip() {
    master_ip=$(ping -c 1 $($KUBECTL get cm ibmcloud-cluster-info -n kube-public -o yaml | grep cluster_address: | awk -F ': ' '{print $2}') |awk -F'[()]' '{print $2;exit}')
}

function get_router_https_port() {
    router_https_port=$($KUBECTL get cm ibmcloud-cluster-info -n kube-public -o yaml | grep cluster_router_https_port: | awk -F ': ' '{print $2}' | sed 's/\"//g')
}

function get_proxy_https_port() {
    proxy_https_port=$($KUBECTL get cm ibmcloud-cluster-info -n kube-public -o yaml | grep proxy_ingress_https_port: | awk -F ': ' '{print $2}' | sed 's/\"//g')
}

function get_proxy_http_port() {
    proxy_http_port=$($KUBECTL get cm ibmcloud-cluster-info -n kube-public -o yaml | grep proxy_ingress_http_port: | awk -F ': ' '{print $2}' | sed 's/\"//g')
}

function get_api_security_port() {
    kube_apiserver_port=$($KUBECTL get cm ibmcloud-cluster-info -n kube-public -o yaml | grep cluster_kube_apiserver_port: | awk -F ': ' '{print $2}' | sed 's/\"//g')
}

function get_credentials() {
  base64_command
  username=$($KUBECTL get secrets platform-auth-idp-credentials -n kube-system -oyaml | grep admin_username: | awk -F ': ' '{print $2}' | $_base64_command)
  password=$($KUBECTL get secrets platform-auth-idp-credentials -n kube-system -oyaml | grep admin_password: | awk -F ': ' '{print $2}' | $_base64_command)
}

function get_auth_token() {
  get_master_ip
  get_router_https_port
  get_credentials
  auth_token=$(curl -s -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" -d "grant_type=password&username=$username&password=$password&scope=openid"  https://$master_ip:$router_https_port/idprovider/v1/auth/identitytoken --insecure | jq '.id_token' |  tr -d '"')
}

function get_arch() {
    arch=$(uname -m)
}

function update_insecure_registries() {

  # update /etc/hosts file to set the mycluster.icp in it.
  cat /etc/hosts | grep ${CLUSTERNAME}.icp
  if [[ $? != 0 ]]; then
    echo -e "\n$ACCESS_IP ${CLUSTERNAME}.icp" |sudo tee -a /etc/hosts
    if [[ $IN_DOCKER == "false" ]]; then
      _insecure_registry_CIDRS=$(docker info -f '{{json .RegistryConfig.IndexConfigs}}')
      if [[ $(echo $_insecure_registry_CIDRS | grep ${CLUSTERNAME}.icp | wc -l | sed 's/^ *//') -eq 0 ]]; then
        if [[ $(uname -s) == 'Darwin' ]]; then
          echo "need to manually add the insecure registry in docker configuration and then restart the docker on Mac OS"
          exit 1
        fi
        echo '{"insecure-registries" : ["${CLUSTERNAME}.icp:8500"]}' |sudo tee -a /etc/docker/daemon.json
        service docker restart
        wait_for_docker_restart
      fi
    fi
  fi
}

function wait_for_docker_restart() {
    typeset -i seconds=0

    echo "Waiting for docker restart."
    while :; do
        docker info 2>/dev/null
        if [[ $? -eq 0 ]]; then
            break
        fi
        sleep 2
        ((seconds=seconds+2))
    done
    echo "docker restart take ${seconds} seconds."
}

function setup_cloudctl() {
  get_master_ip
  get_router_https_port
  get_arch
  if [[ ! -e /usr/local/bin/cloudctl ]]; then
      if [[ $arch == x86_64 ]]; then
          if [[ $(uname -s) == 'Darwin' ]]; then
              curl -kLo cloudctl https://$master_ip:$router_https_port/api/cli/cloudctl-darwin-amd64
          else
            curl -kLo cloudctl https://$master_ip:$router_https_port/api/cli/cloudctl-linux-amd64
          fi
      elif [[ $arch == ppc64le ]]; then
          curl -kLo cloudctl https://$master_ip:$router_https_port/api/cli/cloudctl-linux-ppc64le
      else
          curl -kLo cloudctl https://$master_ip:$router_https_port/api/cli/cloudctl-linux-s390x
      fi
      chmod 755 ./cloudctl
      sudo cp ./cloudctl /usr/local/bin/cloudctl
  fi
}

function setup_helmctl() {
  get_master_ip
  get_router_https_port
  get_arch
  if [[ ! -e /usr/local/bin/helm ]]; then
    if [[ $arch == x86_64 ]]; then
      if [[ $(uname -s) == 'Darwin' ]]; then
        curl -kLo helm-linux.tar.gz https://$master_ip:$router_https_port/api/cli/helm-darwin-amd64.tar.gz
        tar zxvf helm-linux.tar.gz
        sudo cp darwin-amd64/helm /usr/local/bin/helm
      else
        curl -kLo helm-linux.tar.gz https://$master_ip:$router_https_port/api/cli/helm-linux-amd64.tar.gz
        tar zxvf helm-linux.tar.gz
        sudo cp linux-amd64/helm /usr/local/bin/helm
      fi
    elif [[ $arch == ppc64le ]]; then
      curl -kLo helm-linux.tar.gz https://$master_ip:$router_https_port//api/cli/helm-linux-ppc64le.tar.gz
      tar zxvf helm-linux.tar.gz
      sudo cp linux-ppc64le/helm /usr/local/bin/helm
    else
      curl -kLo helm-linux.tar.gz https://$master_ip:$router_https_port/api/cli/helm-linux-s390x
      tar zxvf helm-linux.tar.gz
      sudo cp linux-s390/helm /usr/local/bin/helm
    fi
  fi
  export HELM_HOME=~/.helm
  helm init --client-only --skip-refresh
}

function setup_istioctl() {
  get_master_ip
  get_router_https_port
  get_arch
  if [ ! -e /usr/local/bin/istioctl ]; then
      if [[ $arch == x86_64 ]]; then
        if [[ $(uname -s) == 'Darwin' ]]; then
          curl -kLo istioctl https://$master_ip:$router_https_port/api/cli/istioctl-darwin-amd64
        else
          curl -kLo istioctl https://$master_ip:$router_https_port/api/cli/istioctl-linux-amd64
        fi
      elif [[ $arch == ppc64le ]]; then
          curl -kLo istioctl https://$master_ip:$router_https_port/api/cli/istioctl-linux-ppc64le
      else
          curl -kLo istioctl https://$master_ip:$router_https_port/api/cli/istioctl-linux-s390x
      fi
      chmod 755 ./istioctl
      sudo cp ./istioctl /usr/local/bin/istioctl
  fi
}

function enable_ui() {
   ###install pip
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    sudo -H python get-pip.py
    if [ $? == 0 ]; then
        echo "pip installed"
    fi
    ###install selenium v3.13.0
    sudo pip install --user selenium==3.13.0
    if [ $? == 0 ]; then
        echo "selenium installed"
    fi
    ###Add geckodriver into PATH
    if [[ $(uname -s) == 'Darwin' ]]; then
      sudo  cp $sert_bats_workdir/suites/testui/geckodriver_mac /usr/local/bin/geckodriver
      sudo  chmod a+x /usr/local/bin/geckodriver
    else
      sudo cp $sert_bats_workdir/suites/testui/geckodriver /usr/bin
      sudo chmod a+x /usr/bin/geckodriver
    fi
    ###install firefox web browser and xvfb
    OS=$(uname -a)
    if [[ $OS =~ "Ubuntu" ]]; then
        sudo apt-get update
        sudo apt -y install firefox
        sudo apt-get -y install xvfb gtk2-engines-pixbuf
        sudo apt-get -y install xfonts-cyrillic xfonts-100dpi xfonts-75dpi xfonts-base xfonts-scalable

    elif [[ $OS =~ "sles" ]]; then
        zypper -y install firefox
        sudo zypper install -y xorg-x11-server
    elif [[ $OS =~ "rhel" ]]; then
        sudo yum -y install firefox
        sudo curl -O http://rpmfind.net/linux/centos/7.5.1804/os/x86_64/Packages/xorg-x11-server-Xvfb-1.19.5-5.el7.x86_64.rpm
        sudo rpm -ivh $sert_bats_workdir/xorg-x11-server-Xvfb-1.19.5-5.el7.x86_64.rpm --nodeps
    else
        if [[ -d /Applications/Firefox.app/Contents/MacOS ]]; then
          echo "firefox already installed"
        else
          echo "please install firefox"
        fi
    fi

    #if [ $? == 0 ]; then
    #    echo "firefox installed"
    #fi
    ###start xvfb
    #Xvfb :99 &
    #sleep 3
}

function check_ui_tool() {
    OS=$(uname -a)
    if [[ $OS =~ "Ubuntu" || $OS =~ "sles" ]]; then
       if [[ -e /usr/local/bin/pip && -e /usr/bin/geckodriver ]]; then
          return 0
       else
          enable_ui
       fi
    elif [[  $OS =~ "Linux" ]]; then
      if [[ -e /usr/bin/pip && -d /usr/selenium/webdriver && -e /usr/bin/geckodriver ]]; then
          return 0
      else
         enable_ui
      fi
    elif [[ $OS =~ "Darwin" ]]; then
      if [[ -e /usr/local/bin/pip && -d /Library/Python/2.7/site-packages && -e /usr/local/bin/geckodriver ]]; then
          return 0
      else
         enable_ui
      fi
    fi
}

function get_docker_user_pass() {
  deploy_file=".deploy-amd64-openstack.tfvars"
  get_arch
  case "$arch" in
    x86_64)   deploy_file=".deploy-amd64-openstack.tfvars" ;;
    ppc64le)  deploy_file=".deploy-power-openstack.tfvars" ;;
    s390x)    deploy_file=".deploy-z-openstack.tfvars" ;;
  esac

  if [[ -f $deploy_file ]]; then
    export PRIVATE_REGISTRY_SERVER=$(cat $deploy_file | awk '/private_registry_server/{print $NF}' | sed -e 's/^"//' -e 's/"$//')
    export DOCKER_USERNAME=$(cat $deploy_file | awk '/docker_username/{print $NF}' | sed -e 's/^"//' -e 's/"$//')
    export DOCKER_PASSWORD=$(cat $deploy_file | awk '/docker_password/{print $NF}' | sed -e 's/^"//' -e 's/"$//')
  else
    export PRIVATE_REGISTRY_SERVER=hyc-cloud-private-edge-docker-local.artifactory.swg-devops.com
  fi
}
