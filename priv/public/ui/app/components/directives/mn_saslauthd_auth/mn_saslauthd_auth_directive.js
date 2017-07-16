(function () {
  "use strict";

  angular
    .module('mnSaslauthdAuth', [
      "mnLdapService",
      "mnPromiseHelper"
    ])
    .directive('mnSaslauthdAuth', mnSaslauthdAuthDirective);

  function mnSaslauthdAuthDirective(mnLdapService, mnPromiseHelper) {
    var mnSaslauthdAuth = {
      restrict: 'A',
      scope: {
        rbac: "="
      },
      templateUrl: 'app/components/directives/mn_saslauthd_auth/mn_saslauthd_auth.html',
      controller: controller,
      controllerAs: "saslauthdAuthCtl"
    };

    return mnSaslauthdAuth;

    function controller() {
      var vm = this;
      vm.toggleSaslauthdAuth = toggleSaslauthdAuth;

      activate();

      function activate() {
        mnPromiseHelper(vm, mnLdapService.getSaslauthdAuth())
          .applyToScope("saslauthdAuth")
          .showSpinner("saslauthdAuthLoading");
      }

      function toggleSaslauthdAuth() {
        var config = {
          enabled: !vm.saslauthdAuth.enabled
        };
        mnPromiseHelper(vm, mnLdapService.postSaslauthdAuth(config))
          .applyToScope("saslauthdAuth")
          .showSpinner("saslauthdAuthLoading");
      }
    }
  }
})();
