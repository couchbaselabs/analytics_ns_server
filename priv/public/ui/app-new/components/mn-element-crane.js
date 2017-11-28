var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnElementCrane = (function () {
  "use strict";

  var depots = {};

  MnElementCraneService.annotations = [
    new ng.core.Injectable()
  ];

  MnElementCraneService.prototype.get = get;
  MnElementCraneService.prototype.register = register;
  MnElementCraneService.prototype.unregister = unregister;

  return MnElementCraneService;

  function MnElementCraneService() {
  }

  function register(element, name) {
    depots[name] = element;
  }

  function unregister(name) {
    delete depots[name]
  }

  function get(name) {
    return depots[name];
  }
})();

var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnElementCargo =
  (function () {
    "use strict";

    MnElementCargoComponent.annotations = [
      new ng.core.Component({
        selector: "mn-element-cargo",
        template: "<ng-content></ng-content>",
        inputs: [
          "depot"
        ],
      })
    ];

    MnElementCargoComponent.parameters = [
      ng.core.ElementRef,
      ng.core.Renderer2,
      mn.services.MnElementCrane
    ];

    MnElementCargoComponent.prototype.ngOnInit = ngOnInit;
    MnElementCargoComponent.prototype.ngOnDestroy = ngOnDestroy;

    return MnElementCargoComponent;

    function MnElementCargoComponent(el, renderer2, mnElementCrane) {
      this.el = el;
      this.renderer = renderer2;
      this.mnElementCrane = mnElementCrane;
    }

    function ngOnInit() {
      this.depotElement = this.mnElementCrane.get(this.depot);
      this.renderer.appendChild(this.depotElement.nativeElement, this.el.nativeElement);
    }

    function ngOnDestroy() {
      this.renderer.removeChild(this.depotElement.nativeElement, this.el.nativeElement);
    }
  })();

var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnElementDepot =
  (function () {
    "use strict";

    MnElementDepotComponent.annotations = [
      new ng.core.Component({
        selector: "mn-element-depot",
        template: "<ng-content></ng-content>",
        inputs: [
          "name"
        ],
      })
    ];

    MnElementDepotComponent.parameters = [
      ng.core.ElementRef,
      mn.services.MnElementCrane
    ];

    MnElementDepotComponent.prototype.ngOnInit = ngOnInit;
    MnElementDepotComponent.prototype.ngOnDestroy = ngOnDestroy;

    return MnElementDepotComponent;

    function MnElementDepotComponent(el, mnElementCrane) {
      this.el = el;
      this.mnElementCrane = mnElementCrane;
    }

    function ngOnInit() {
      this.mnElementCrane.register(this.el, this.name);
    }

    function ngOnDestroy() {
      this.mnElementCrane.unregister(this.name);
    }
  })();


var mn = mn || {};
mn.modules = mn.modules || {};
mn.modules.MnElementModule =
  (function () {
    "use strict";

    MnElementModule.annotations = [
      new ng.core.NgModule({
        declarations: [
          mn.components.MnElementDepot,
          mn.components.MnElementCargo
        ],
        exports: [
          mn.components.MnElementDepot,
          mn.components.MnElementCargo
        ],
        imports: [],
        providers: [
          mn.services.MnElementCrane
        ]
      })
    ];

    return MnElementModule;

    function MnElementModule() {
    }
  })();
