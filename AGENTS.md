This is the distro production repo for HermetixOS, an opinionated config/distro built on NixOS and around Hermes Agent. This is not a personal config, do not include personal information, user config, host hardware config, etc in this repo.

Do not leave comments in code.

Only maintain two modules: The nixosModule and the homeManagerModule. If it's core HermetixOS functionality, it goes in the nixosModule. If it's desktop/user/rice functionality like DE/WM/Aesthetic, it goes in HM module.