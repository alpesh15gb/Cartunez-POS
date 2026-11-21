<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Magento\Cms\Model\PageFactory;
use Magento\Cms\Model\ResourceModel\Page as PageResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * Home page: the "Select your vehicle" finder right under the hero, and the
 * product rows in this order: On sale, Best sellers, Shop by brand, New
 * arrivals, Featured. Each part is added only when missing, so the rest of the
 * page (and anything edited in Content > Pages > Home Page) stays as it is.
 */
class HomeFinderAndRows implements DataPatchInterface
{
    private const FINDER = '{{block class="Cartunez\\Storefront\\Block\\VehicleFinder" '
        . 'template="Cartunez_Storefront::finder.phtml" mode="hero"}}';
    private const BEST = '{{block class="Cartunez\\Storefront\\Block\\ProductRow" '
        . 'template="Cartunez_Storefront::row.phtml" list="best"}}';
    private const NEWEST = '{{block class="Cartunez\\Storefront\\Block\\ProductRow" '
        . 'template="Cartunez_Storefront::row.phtml" list="new" skip_if_best_empty="1"}}';

    public function __construct(
        private readonly PageFactory $pageFactory,
        private readonly PageResource $pageResource
    ) {
    }

    public function apply(): self
    {
        $page = $this->pageFactory->create();
        $this->pageResource->load($page, 'home', 'identifier');
        if (!$page->getId()) {
            return $this;
        }
        $content = (string)$page->getContent();
        $before = $content;

        if (!str_contains($content, 'Block\\VehicleFinder')) {
            $content = $this->after($content, '{{block id="cartunez-hero"}}', self::FINDER)
                ?? self::FINDER . "\n" . $content;
        }
        if (!str_contains($content, 'list="best"')) {
            $content = $this->afterDirective($content, 'Block\\SaleProducts', self::BEST)
                ?? $this->beforeDirective($content, 'Block\\BrandCards', self::BEST)
                ?? $this->beforeFeatured($content, self::BEST)
                ?? $content . "\n" . self::BEST;
        }
        if (!str_contains($content, 'list="new"')) {
            $content = $this->afterDirective($content, 'Block\\BrandCards', self::NEWEST)
                ?? $this->beforeFeatured($content, self::NEWEST)
                ?? $content . "\n" . self::NEWEST;
        }
        // Every published part can be ordered: "In stock now" says nothing useful.
        $content = str_replace('<span class="cz-kicker">In stock now</span>', '<span class="cz-kicker">Hand-picked</span>', $content);

        if ($content !== $before) {
            $page->setContent($content);
            $this->pageResource->save($page);
        }
        return $this;
    }

    private function after(string $content, string $marker, string $insert): ?string
    {
        $at = strpos($content, $marker);
        if ($at === false) {
            return null;
        }
        $end = $at + strlen($marker);
        return substr($content, 0, $end) . "\n" . $insert . substr($content, $end);
    }

    /** After the {{block ...}} directive that names [class]. */
    private function afterDirective(string $content, string $class, string $insert): ?string
    {
        $at = strpos($content, $class);
        if ($at === false) {
            return null;
        }
        $end = strpos($content, '}}', $at);
        if ($end === false) {
            return null;
        }
        $end += 2;
        return substr($content, 0, $end) . "\n" . $insert . substr($content, $end);
    }

    /** Before the {{block ...}} directive that names [class]. */
    private function beforeDirective(string $content, string $class, string $insert): ?string
    {
        $at = strpos($content, $class);
        if ($at === false) {
            return null;
        }
        $start = strrpos(substr($content, 0, $at), '{{block');
        if ($start === false) {
            return null;
        }
        return substr($content, 0, $start) . $insert . "\n" . substr($content, $start);
    }

    /** Before the heading of the "Featured products" widget. */
    private function beforeFeatured(string $content, string $insert): ?string
    {
        $at = strpos($content, 'id="cz-new"');
        if ($at === false) {
            return null;
        }
        $start = strrpos(substr($content, 0, $at), '<div class="cz-section-head">');
        if ($start === false) {
            return null;
        }
        return substr($content, 0, $start) . $insert . "\n" . substr($content, $start);
    }

    public static function getDependencies(): array
    {
        return [SaleSection::class];
    }

    public function getAliases(): array
    {
        return [];
    }
}
