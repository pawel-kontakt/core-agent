# Agent hub repo

This is my agent context hub repository and workspace, memory and skills. Prefer this repo setup.
Directives in this file should override repo level claude.md files.

# My work context

I am a pod lead of a Temperature Monitoring solution. 
My tasks are mainly designing and planning work.
Managing a team of github users:

| Name                 | Email                 | Github        |
|----------------------|-----------------------|---------------|
| Paweł Stokowiec (me) | pawel@kontakt.io      | pawel-kontakt |
| Andriy Hnezdyuk      | a.hnezdyuk@kontakt.io | hnezdyuk-kio  |
| Krzysztof Pala       | k.pala@kontakt.io     | kpala-kio     |

Claude your role: I want you to be my senior team member, exploring the code base, explaining how things works 

## kio-apps

This is my main repository, where majority of work is happening. Default location for work related to TM app features.

Workspace: /Users/kontakt/IdeaProjects/kio-apps

Agents: @/Users/kontakt/IdeaProjects/kio-apps/services/temperature-monitoring/AGENTS.md

Main modules:
- `/kio-apps/services/temeperature-monitoring` - main backend implementation for TM App solution
- `/kio-apps/frontend/projects/temperature-monitoring` - TM App Web application
- `/kio-apps/services/starlink/alerts` - app module responsible for receiving alerts and their resolution

TM Solution dependencies
- **Location Services** - read and manage location topology, Campuses, Floors, Rooms, floor map
    - [Location read API](../kio-apps/api-spec/apps-location-api/apps-location-api.yaml) API to read topology in the optimal way. [apps-location](../kio-apps/services/apps-location)
    - [Smart Location API](../kio-apps/api-spec/smart-location-facade/smart-location-facade-api.yaml) API to manage topology and devices deployment (physical deployment). [smart-location-facade](../kio-apps/services/smart-location/smart-location-facade)
    - [Smart Location Internal API](../kio-apps/api-spec/smart-location-facade/smart-location-facade-internal-api.yaml) API to use from the back-channel processing services (no user context). [smart-location-facade internal](../kio-apps/services/smart-location/smart-location-facade).
- **Entity Management API**
    - [Entity Management API](../kio-apps/api-spec/entity-management/entity-management-api.yaml) CRUD API for Entities. [entity-management](../kio-apps/services/entity-management).
    - [Entity Management Internal API](../kio-apps/api-spec/entity-management/entity-management-internal-api.yaml) API for Entities to use in the back-channel processing services. [entity-management internal](../entity-management/api)
- **Alerts Module** - component responsible for alerts processing, triggering and notifications.
    - [Alerts API](../kio-apps/api-spec/app-alerts/app-alerts-api-bundle.yaml) App alerts API. [alerts](../kio-apps/services/starlink/alerts).
- **Data generator** - [Ramble API](../kio-apps/api-spec/ramble-api/ramble-api.yaml) - api to generated simulated data. [ramble-api](../kio-apps/services/data-generator)

## compute-temperature-monitoring

Data processing layer for temp monitoring.
Workspace: /Users/kontakt/IdeaProjects/compute-temperature-monitoring

Implementation from this module is critical today for solution, but overcomplicated and my goal is to simplify it, integrate into kio-apps repo and extract S3 and aggregation logic to the data-platform spark jobs.

## hardware-py-tools

Workspace: /Users/kontakt/IdeaProjects/hardware-py-tools
Don't modify any code or make any github changes to this repository. 
It contains kio tool used by the kio-cli plugin - very useful to debug physical devices remotely.
Code from this repo explains firmware logic and device configuration protocol. 

## device-management

Workspace: /Users/kontakt/IdeaProjects/dm-api
Device Management (dm-api), API to manage devices configuration, device metadata, certificates. 
Main interface for communication with the devices.

## telemetry-faker

Workspace with implementation: 
Testing support service - api to simulate devices readings, device configuration tool.
[Telemetry Faker API](../kio-apps/api-spec/telemetry-faker/telemetry-faker-api.yaml) Telemetry faker API to simulate device behaviour. 
This service also contains e2e test for the kio-cloud platform, these can serve as a source of knowledge, but don't include any work related to these tests as tm solution using different framework.

## android Kio Setup Manager 

Workspace: /Users/kontakt/IdeaProjects/kio-android-apps/kio-setup-manager
This is Android app users used to install temp monitors, its using temp monitoring api from kio-apps

## infra

### Infra repository
Workspace: /Users/kontakt/IdeaProjects/infra2
This is terraform code to provision all cloud environments. This code depends on external submodules from terraform-modules, every env is re-using module as per-env instance of the app module.

### terraform-modules repository
Workspace: /Users/kontakt/IdeaProjects/terraform-modules
This is apps and other resources modules re-used between envs.

### kio-services-infra argocd
Workspace: /Users/kontakt/IdeaProjects/kio-services-infra
This is runtime and configuration management of services deployed in k8s cluster.
Prefer configuration of services over here, tf infra and modules should only depend on the secrets and properties unique to specific deployed env.