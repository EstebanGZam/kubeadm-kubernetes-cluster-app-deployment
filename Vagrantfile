# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  # Base configuration
  config.vm.box = "bento/ubuntu-24.04"
  config.vm.box_check_update = false

  # Common VirtualBox configuration
  config.vm.provider "virtualbox" do |vb|
    vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    vb.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
  end

  # ======================
  # Master Node
  # ======================
  config.vm.define "k8s-master" do |master|
    master.vm.hostname = "k8s-master"

    # Network configuration - Fixed IP in private network
    master.vm.network "private_network", ip: "192.168.56.10"

    # Resource allocation
    master.vm.provider "virtualbox" do |vb|
      vb.name = "k8s-master"
      vb.memory = "2048"
      vb.cpus = 2
    end

    # Provisioning
    master.vm.provision "shell", path: "provisioning/common.sh"
    master.vm.provision "shell", path: "provisioning/master.sh", args: ["192.168.56.10"]
  end

  # ======================
  # Worker Nodes (dynamic)
  # ======================

  workers = {
    "k8s-worker1" => "192.168.56.11",
    "k8s-worker2" => "192.168.56.12",
  }

  workers.each do |name, ip|
    config.vm.define name do |worker|
      worker.vm.hostname = name

      # Network configuration
      worker.vm.network "private_network", ip: ip

      # Resource allocation
      worker.vm.provider "virtualbox" do |vb|
        vb.name = name
        vb.memory = "1536"
        vb.cpus = 1
      end

      # Provisioning
      worker.vm.provision "shell", path: "provisioning/common.sh"
      worker.vm.provision "shell", path: "provisioning/worker.sh", args: [ip]
    end
  end
end