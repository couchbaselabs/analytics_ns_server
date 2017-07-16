(function () {
  "use strict";

  angular
    .module("mnUserRoles")
    .controller("mnUserRolesResetPasswordDialogController", mnUserRolesResetPasswordDialogController);

  function mnUserRolesResetPasswordDialogController($scope, mnUserRolesService, $uibModalInstance, mnPromiseHelper, user) {
    var vm = this;

    vm.user = user;
    vm.userID = vm.user.id;
    vm.save = save;

    function save() {
      if (vm.form.$invalid) {
        return;
      }
      mnPromiseHelper(vm, mnUserRolesService.addUser(vm.user, vm.user.roles, true), $uibModalInstance)
        .showGlobalSpinner()
        .catchErrors()
        .broadcast("reloadRolesPoller")
        .closeOnSuccess()
        .showGlobalSuccess("Password reset successfully!");
    }
  }
})();
