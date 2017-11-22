var mn = mn || {};
mn.modules = mn.modules || {};
mn.modules.MnAuth =
  (function () {
    "use strict";

    var MnAuth =
        ng.core.NgModule({
          declarations: [
            mn.components.MnAuth,
            mn.directives.MnFocus
          ],
          imports: [
            ng.platformBrowser.BrowserModule,
            ng.forms.ReactiveFormsModule
          ],
          entryComponents: [
            mn.components.MnAuth
          ],
          providers: [
            mn.services.MnAuth,
            ng.forms.Validators,
            ng.common.Location
          ]
        })
        .Class({
          constructor: function MnAuthModule() {},
        });

    return MnAuth;
  })();
