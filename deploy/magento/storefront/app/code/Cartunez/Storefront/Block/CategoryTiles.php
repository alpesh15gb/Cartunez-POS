<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Block;

use Cartunez\Storefront\Model\ShopCategories;
use Magento\Framework\DataObject\IdentityInterface;
use Magento\Framework\View\Element\Template;
use Magento\Framework\View\Element\Template\Context;

/**
 * "Upgrades for every drive": six department tiles on the home page. Each tile
 * opens its POS category when one exists (ShopCategories: "Audio", "Interior",
 * "Lighting"..., or the longer names) and shows its real item count; otherwise
 * it opens a search for the department word and shows no count.
 */
class CategoryTiles extends Template implements IdentityInterface
{
    /** department => [title, text, link text, icon, search word, accent] */
    private const TILES = [
        'audio' => ['Audio & infotainment', 'Android head units, component speakers, amplifiers and subwoofers', 'Explore audio', 'speaker', 'audio', 'cyan'],
        'interior' => ['Interior makeovers', 'Seat covers, floor mats, ambient lighting and trims', 'View interiors', 'seat', 'interior', 'red'],
        'lighting' => ['Exterior & lighting', 'Projector and LED headlamps, fog lamps and DRLs', 'Upgrade lighting', 'light', 'lighting', 'cyan'],
        'safety' => ['Dashcams & safety', 'Dash cameras and drive safety accessories', 'View safety', 'camera', 'dashcam', 'cyan'],
        'styling' => ['Styling & sun control', 'Sun-control film, styling kits and exterior accents', 'View styling', 'sun', 'styling', 'red'],
        'performance' => ['Performance & detailing', 'Air filters, car care, polish and protection', 'View detailing', 'gauge', 'performance', 'green'],
    ];

    public function __construct(
        Context $context,
        private readonly ShopCategories $shopCategories,
        array $data = []
    ) {
        parent::__construct($context, $data);
    }

    /**
     * @return array<int, array{key: string, title: string, text: string, cta: string, icon: string, url: string, count: int, accent: string}>
     */
    public function getTiles(): array
    {
        $found = $this->shopCategories->resolve();
        $tiles = [];
        foreach (self::TILES as $key => [$title, $text, $cta, $icon, $word, $accent]) {
            $category = $found[$key] ?? null;
            $tiles[] = [
                'key' => $key,
                'title' => (string)__($title),
                'text' => (string)__($text),
                'cta' => (string)__($cta),
                'icon' => $icon,
                'url' => $category ? $category['url'] : $this->getUrl('catalogsearch/result', ['_query' => ['q' => $word]]),
                'count' => $category ? $category['count'] : 0,
                'accent' => $accent,
            ];
        }
        return $tiles;
    }

    public function getIdentities(): array
    {
        return $this->shopCategories->getIdentities();
    }
}
