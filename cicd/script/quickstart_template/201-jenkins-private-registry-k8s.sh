#!/bin/bash
function print_usage() {
  cat <<EOF
https://github.com/Azure/azure-quickstart-templates/tree/master/201-jenkins-acr
Command
  $0
Arguments
  --vm_user_name|-u        [Required] : VM user name
  --git_url|-g             [Required] : Git URL with a Dockerfile in it's root
  --registry|-r            [Required] : Registry url targeted by the pipeline
  --repository|-rr         [Required] : Repository targeted by the pipeline
  --jenkins_fqdn|-jf       [Required] : Jenkins FQDN
  --kubernetes_master_fqdn|-kmf [Required] : Kubernete master FQDN
  --kubernetes_user_name|-kun [Required] : Kubernete master user name
  --kubernetes_private_key|-kpk [Required] : kubernetes private key log in to master FQDN
  --artifacts_location|-al            : Url used to reference other scripts/artifacts.
  --sas_token|-st                     : A sas token needed if the artifacts location is private.
  --registry_user_name|-ru : Registry user name
  --registry_password|-rp : Registry password (Required if user name not empty)
  --docker_engine_download_repo|-dedr : docker-engine download repo
EOF
}

function throw_if_empty() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    echo "Parameter '$name' cannot be empty." 1>&2
    print_usage
    exit -1
  fi
}

function run_util_script() {
  local script_path="$1"
  shift
  curl --silent "${artifacts_location}${script_path}${artifacts_location_sas_token}" | sudo bash -s -- "$@"
  local return_value=$?
  if [ $return_value -ne 0 ]; then
    >&2 echo "Failed while executing script '$script_path'."
    exit $return_value
  fi
}
function install_kubectl() {
  if !(command -v kubectl >/dev/null); then
    kubectl_file="/usr/local/bin/kubectl"
    sudo curl -L -s -o $kubectl_file https://osscicd.blob.core.chinacloudapi.cn/tools/kubectl
    sudo chmod +x $kubectl_file
  fi
}
function install_docker_fromMirror() {
  curl --max-time 60 -fsSL https://aptdocker.azureedge.net/gpg | apt-key add -
  sudo add-apt-repository "deb [arch=amd64] ${docker_engine_download_repo} ubuntu-xenial main"
  sudo apt-get update --fix-missing
  apt-cache policy docker-engine
  sudo apt-get install -y unzip docker-engine nginx apache2-utils
}
function copy_kube_config() {
  kubconfigdir=$HOME/.kube
  sudo mkdir -p $kubconfigdir
  k8sprivatekey_rsa=/home/$vm_user_name/.ssh/k8sprivatekey_rsa
  sudo touch $k8sprivatekey_rsa
  echo "${kubernetes_private_key}" | base64 -d | sudo tee ${k8sprivatekey_rsa}
  sudo chmod 400 $k8sprivatekey_rsa
  sudo mkdir /var/lib/jenkins/.kube/
  sudo scp -i $k8sprivatekey_rsa -o StrictHostKeyChecking=no $kubernetes_user_name@$kubernetes_master_fqdn:.kube/config $kubconfigdir
  sudo cp $kubconfigdir/config /var/lib/jenkins/.kube/config
  sudo chmod 775 /var/lib/jenkins/.kube/config
  export KUBECONFIG=$kubconfigdir/config
}
# create a k8s registry secrect and bind it with default service account
function bind_k8s_registry_secret_to_service_account() {
  kubectl create secret docker-registry testprivateregistrykey --docker-server="${registry}" --docker-username="${registry_user_name}" --docker-password="${registry_password}" --docker-email=fakemail@microsoft.com
  kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "testprivateregistrykey"}]}'
}

#defaults
artifacts_location="https://raw.githubusercontent.com/Azure/devops-sample-solution-for-azure-china/master-dev/cicd/script/"
jenkins_version_location="https://raw.githubusercontent.com/Azure/devops-sample-solution-for-azure-china/master-dev/cicd/script/jenkins/jenkins-verified-ver"
while [[ $# > 0 ]]
do
  key="$1"
  shift
  case $key in
    --vm_user_name|-u)
      vm_user_name="$1"
      shift
      ;;
    --git_url|-g)
      git_url="$1"
      shift
      ;;
    --registry|-r)
      registry="$1"
      shift
      ;;
    --registry_user_name|-ru)
      registry_user_name="$1"
      shift
      ;;
    --registry_password|-rp)
      registry_password="$1"
      shift
      ;;
    --repository|-rr)
      repository="$1"
      shift
      ;;
    --jenkins_fqdn|-jf)
      jenkins_fqdn="$1"
      shift
      ;;
    --artifacts_location|-al)
      artifacts_location="$1"
      shift
      ;;
    --sas_token|-st)
      artifacts_location_sas_token="$1"
      shift
      ;;
    --kubernetes_master_fqdn|-kmf)
      kubernetes_master_fqdn="$1"
      shift
      ;;
    --kubernetes_user_name|-kun)
      kubernetes_user_name="$1"
      shift
      ;;
    --kubernetes_private_key|-kpk)
      kubernetes_private_key="$1"
      shift
      ;;
    --docker_engine_download_repo|-dedr)
      docker_engine_download_repo="$1"
      shift
      ;;
    --help|-help|-h)
      print_usage
      exit 13
      ;;
    *)
      echo "ERROR: Unknown argument '$key' to script '$0'" 1>&2
      exit -1
  esac
done

throw_if_empty --vm_user_name $vm_user_name
throw_if_empty --git_url $git_url
throw_if_empty --registry $registry

if [ ! -z "$registry_user_name" ] ; then
  throw_if_empty --registry_password $registry_password
fi

throw_if_empty --jenkins_fqdn $jenkins_fqdn
throw_if_empty --kubernetes_master_fqdn $kubernetes_master_fqdn
throw_if_empty --kubernetes_user_name $kubernetes_user_name

if [ -z "$docker_engine_download_repo" ] ; then
  docker_engine_download_repo="https://mirror.azure.cn/docker-engine/apt/repo"
fi

if [ -z "$repository" ]; then
  repository="${vm_user_name}/myfirstapp"
fi

#install jenkins
run_util_script "jenkins/install_jenkins.sh" -jf "${jenkins_fqdn}" -al "${artifacts_location}" -st "${artifacts_location_sas_token}" -jvl "${jenkins_version_location}"

#install git
sudo apt-get install git --yes

#install docker if not already installed
if !(command -v docker >/dev/null); then
  install_docker_fromMirror
fi

# config insecure registry if user name is empty
if [ -z "$registry_user_name" ] ; then
  daemon_file="/etc/docker/daemon.json"

  sudo apt-get install -y -q git jq moreutils
  sudo cat "$daemon_file" | jq ".\"insecure-registries\"[0]=\"$registry\"" | sudo sponge "$daemon_file"
  sudo service docker restart
fi

#sleep 5 seconds wait for docker to boot up
sleep 5
#make sure jenkins has access to docker cli
sudo gpasswd -a jenkins docker
skill -KILL -u jenkins
sudo service jenkins restart

# check jenkins is fully up
echo "waiting jenkins fully up at $(date "+%Y-%m-%d %H:%M:%S")"
jenkins_up_counter=0
jenkins_fully_up=1
while [[ $(curl -s -w "%{http_code}" http://localhost:8080/ -o /dev/null) == "503" ]]; do
  if [[ "$jenkins_up_counter" -gt 30 ]]; then
    echo "jenkins still not fully up at $(date "+%Y-%m-%d %H:%M:%S")"
    jenkins_fully_up=0
    break
  else
    let jenkins_up_counter++
  fi
  sleep 10
done
if [ ! -z $jenkins_fully_up ] ; then
  echo "jenkins fully up at $(date "+%Y-%m-%d %H:%M:%S"), retried $jenkins_up_counter time(s)."
fi

echo "Including the pipeline"
run_util_script "jenkins/add-docker-build-deploy-k8s.sh" -j "http://localhost:8080/" -ju "admin" -g "${git_url}" -r "${registry}" -ru "${registry_user_name}"  -rp "${registry_password}" -rr "$repository" -sps "* * * * *" -al "$artifacts_location" -st "$artifacts_location_sas_token"
install_kubectl
copy_kube_config
kubectl cluster-info
bind_k8s_registry_secret_to_service_account
